;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; ghc-check.el
;;;

;; Author:  Kazu Yamamoto <Kazu@Mew.org>
;; Created: Mar  9, 2014

;;; Code:

;; todo:
;; * hlint
;; * multiple Mains in the same directory

(require 'ghc-func)
(require 'ghc-process)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; stolen from flymake.el
(defface ghc-face-error
  '((((supports :underline (:style wave)))
     :underline (:style wave :color "Red1"))
    (t
     :inherit error))
  "Face used for marking error lines."
  :group 'ghc)

(defface ghc-face-warn
  '((((supports :underline (:style wave)))
     :underline (:style wave :color "DarkOrange"))
    (t
     :inherit warning))
  "Face used for marking warning lines."
  :group 'ghc)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ghc-check-syntax ()
  (interactive)
  (ghc-with-process 'ghc-check-send 'ghc-check-callback))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(ghc-defstruct hilit-info file line col msg err)

(defun ghc-check-send ()
  (concat "check " ghc-process-original-file "\n"))

(defun ghc-check-callback ()
  (let ((regex "^\\([^\n\0]*\\):\\([0-9]+\\):\\([0-9]+\\): *\\(.+\\)")
	info infos)
    (while (re-search-forward regex nil t)
      (let* ((file (match-string 1))
	     (line (string-to-number (match-string 2)))
	     (col  (string-to-number (match-string 3)))
	     (msg  (match-string 4))
	     (err  (not (string-match "^Warning" msg)))
	     (info (ghc-make-hilit-info
		    :file file
		    :line line
		    :col  col
		    :msg  msg
		    :err  err)))
	(setq infos (cons info infos))))
    (setq infos (nreverse infos))
    (cond
     (infos
      (let ((file ghc-process-original-file)
	    (buf ghc-process-original-buffer))
	(ghc-check-highlight-original-buffer file buf infos)))
     (t
      (with-current-buffer ghc-process-original-buffer
	(remove-overlays (point-min) (point-max) 'ghc-check t))))
    (with-current-buffer ghc-process-original-buffer
      (let ((len (length infos)))
	(if (= len 0)
	    (setq mode-line-process "")
	  (let* ((errs (ghc-filter 'ghc-hilit-info-get-err infos))
		 (elen (length errs))
		 (wlen (- len elen)))
	    (setq mode-line-process (format " %d:%d" elen wlen))))))))

(defun ghc-check-highlight-original-buffer (ofile buf infos)
  (with-current-buffer buf
    (remove-overlays (point-min) (point-max) 'ghc-check t)
    (save-excursion
      (goto-char (point-min))
      (dolist (info infos)
	(let ((line (ghc-hilit-info-get-line info))
	      (msg  (ghc-hilit-info-get-msg  info))
	      (file (ghc-hilit-info-get-file info))
	      (err  (ghc-hilit-info-get-err  info))
	      beg end ovl)
	  ;; FIXME: This is the Shlemiel painter's algorithm.
	  ;; If this is a bottleneck for a large code, let's fix.
	  (goto-char (point-min))
	  (cond
	   ((string= ofile file)
	    (forward-line (1- line))
	    (while (eq (char-after) 32) (forward-char))
	    (setq beg (point))
	    (forward-line)
	    (setq end (1- (point))))
	   (t
	    (setq beg (point))
	    (forward-line)
	    (setq end (point))))
	  (setq ovl (make-overlay beg end))
	  (overlay-put ovl 'ghc-check t)
	  (overlay-put ovl 'ghc-file file)
	  (overlay-put ovl 'ghc-msg msg) ;; should be list
	  (let ((face (if err 'ghc-face-error 'ghc-face-warn)))
	    (overlay-put ovl 'face face)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ghc-display-errors ()
  (interactive)
  (let* ((ovls (ghc-check-overlay-at (point)))
	 (errs (mapcar (lambda (ovl) (overlay-get ovl 'ghc-msg)) ovls)))
    (if (null ovls)
	(message "No errors or warnings")
      (ghc-display
       nil
       (lambda ()
	 (insert (overlay-get (car ovls) 'ghc-file) "\n\n")
	 (mapc (lambda (x) (insert x "\n")) errs))))))

(defun ghc-check-overlay-at (p)
  (let ((ovls (overlays-at p)))
    (ghc-filter (lambda (ovl) (overlay-get ovl 'ghc-check)) ovls)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ghc-goto-prev-error ()
  (interactive)
  (let* ((here (point))
	 (ovls0 (ghc-check-overlay-at here))
	 (end (if ovls0 (overlay-start (car ovls0)) here))
	 (ovls1 (overlays-in (point-min) end))
	 (ovls2 (ghc-filter (lambda (ovl) (overlay-get ovl 'ghc-check)) ovls1))
	 (pnts (mapcar 'overlay-start ovls2)))
    (if pnts (goto-char (apply 'max pnts)))))

(defun ghc-goto-next-error ()
  (interactive)
  (let* ((here (point))
	 (ovls0 (ghc-check-overlay-at here))
	 (beg (if ovls0 (overlay-end (car ovls0)) here))
	 (ovls1 (overlays-in beg (point-max)))
	 (ovls2 (ghc-filter (lambda (ovl) (overlay-get ovl 'ghc-check)) ovls1))
	 (pnts (mapcar 'overlay-start ovls2)))
    (if pnts (goto-char (apply 'min pnts)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ghc-check-insert-from-warning ()
  (interactive)
  (dolist (data (mapcar (lambda (ovl) (overlay-get ovl 'ghc-msg)) (ghc-check-overlay-at (point))))
    (save-excursion
      (cond
       ((string-match "Inferred type: \\|no type signature:" data)
	(beginning-of-line)
	(insert-before-markers (ghc-extract-type data) "\n"))
       ((string-match "lacks an accompanying binding" data)
	(beginning-of-line)
	(when (looking-at "^\\([^ ]+\\) *::")
	  (save-match-data
	    (forward-line)
	    (if (not (bolp)) (insert "\n")))
	  (insert (match-string 1) " = undefined\n")))
       ;; GHC 7.8 uses Unicode for single-quotes.
       ((string-match "Not in scope: `\\([^'\n\0]+\\)'" data)
	(let ((sym (match-string 1 data)))
	  (if (y-or-n-p (format "Import module for %s?" sym))
	      (ghc-ins-mod sym)
	    (unless (re-search-forward "^$" nil t)
	      (goto-char (point-max))
	      (insert "\n"))
	    (insert "\n" (ghc-enclose sym) " = undefined\n"))))
       ((string-match "Pattern match(es) are non-exhaustive" data)
	(let* ((fn (ghc-get-function-name))
	       (arity (ghc-get-function-arity fn)))
	  (ghc-insert-underscore fn arity)))
       ((string-match "Found:\0[ ]*\\([^\0]+\\)\0Why not:\0[ ]*\\([^\0]+\\)" data)
	(let ((old (match-string 1 data))
	      (new (match-string 2 data)))
	  (beginning-of-line)
	  (when (search-forward old nil t)
	    (let ((end (point)))
	      (search-backward old nil t)
	      (delete-region (point) end))
	    (insert new))))
       (t
	(message "Nothing is done"))))))

(defun ghc-extract-type (str)
  (with-temp-buffer
    (insert str)
    (goto-char (point-min))
    (when (re-search-forward "Inferred type: \\|no type signature:\\( \\|\0 +\\)?" nil t)
      (delete-region (point-min) (point)))
    (when (re-search-forward " forall [^.]+\\." nil t)
      (replace-match ""))
    (while (re-search-forward "\0 +" nil t)
      (replace-match " "))
    (goto-char (point-min))
    (while (re-search-forward "\\[Char\\]" nil t)
      (replace-match "String"))
    (re-search-forward "\0" nil t)
    (buffer-substring-no-properties (point-min) (1- (point)))))

(defun ghc-get-function-name ()
  (save-excursion
    (beginning-of-line)
    (when (looking-at "\\([^ ]+\\) ")
      (match-string 1))))

(defun ghc-get-function-arity (fn)
  (when fn
    (save-excursion
      (let ((regex (format "^%s *::" (regexp-quote fn))))
	(when (re-search-backward regex nil t)
	  (ghc-get-function-arity0))))))

(defun ghc-get-function-arity0 ()
  (let ((end (save-excursion (end-of-line) (point)))
	(arity 0))
    (while (search-forward "->" end t)
      (setq arity (1+ arity)))
    arity))

(defun ghc-insert-underscore (fn ar)
  (when fn
    (let ((arity (or ar 1)))
      (save-excursion
	(goto-char (point-max))
	(re-search-backward (format "^%s *::" (regexp-quote fn)))
	(forward-line)
	(re-search-forward "^$" nil t)
	(insert fn)
	(dotimes (i arity)
	  (insert " _"))
	(insert  " = error \"" fn "\"")))))

(provide 'ghc-check)