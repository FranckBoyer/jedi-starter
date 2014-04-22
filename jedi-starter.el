;; Package housekeeping

(add-to-list 'load-path "~/.emacs.d")
(require 'package)
(package-initialize)
(add-to-list 'package-archives
	     '("melpa" . "http://melpa.milkbox.net/packages/") t)

(defvar local-packages
  '(auto-complete epc jedi projectile))

(defun uninstalled-packages (packages)
  (delq nil
	(mapcar (lambda (p) (if (package-installed-p p nil) nil p)) packages)))

;; This delightful bit adapted from:
;; http://batsov.com/articles/2012/02/19/package-management-in-emacs-the-good-the-bad-and-the-ugly/

(let ((need-to-install (uninstalled-packages local-packages)))
  (when need-to-install
    (progn
      (package-refresh-contents)
      (dolist (p need-to-install)
	(package-install p)))))

(defvar jedi-config:use-system-python nil
  "Set to non-nil if not using jedi:install-server.
Will use system python and active environment for Jedi server.")

(defvar jedi-config:add-system-virtualenv t
  "Set to non-nil to also point Jedi towards the active $VIRTUAL_ENV, if any")

;; Small helper to scrape text from shell output
(defun get-shell-output (cmd)
  (replace-regexp-in-string "[ \t\n]*$" "" (shell-command-to-string cmd)))

;; Ensure that PATH is taken from shell
;; Necessary on some environments if not relying on Jedi server install
;; Taken from: http://stackoverflow.com/questions/8606954/path-and-exec-path-set-but-emacs-does-not-find-executable

(defun set-exec-path-from-shell-PATH ()
  "Set up Emacs' `exec-path' and PATH environment variable to match that used by the user's shell."
  (interactive)
  (let ((path-from-shell (get-shell-output "$SHELL --login -i -c 'echo $PATH'")))
    (setenv "PATH" path-from-shell)
    (setq exec-path (split-string path-from-shell path-separator))))

;; Helper to get virtualenv from shell
(defun get-active-virtualenv ()
  (let ((venv (get-shell-output "$SHELL -c 'echo $VIRTUAL_ENV'")))
    (if (> (length venv) 0) venv nil)))

(add-hook
 'after-init-hook
 '(lambda ()
    ;; Auto-complete
    (require 'auto-complete-config)
    (ac-config-default)

    ;; Jedi
    (require 'jedi)

    ;; (Many) config helpers follow

    ;; Alternative methods of finding the current project root
    ;; Method 1: basic
    (defun get-project-root (buf repo-file &optional init-file)
      "Just uses the vc-find-root function to figure out the project root.
       Won't always work for some directory layouts."
      (let* ((buf-dir (expand-file-name (file-name-directory (buffer-file-name buf))))
	     (project-root (vc-find-root buf-dir repo-file)))
	(if project-root
	    (expand-file-name project-root)
	  nil)))

    ;; Method 2: slightly more robust
    (defun get-project-root-with-file (buf repo-file &optional init-file)
      "Guesses that the python root is the less 'deep' of either:
         -- the root directory of the repository, or
         -- the directory before the first directory after the root
            having the init-file file (e.g., '__init__.py'."

      ;; make list of directories from root, removing empty
      (defun make-dir-list (path)
        (delq nil (mapcar (lambda (x) (and (not (string= x "")) x))
                          (split-string path "/"))))
      ;; convert a list of directories to a path starting at "/"
      (defun dir-list-to-path (dirs)
        (mapconcat 'identity (cons "" dirs) "/"))
      ;; a little something to try to find the "best" root directory
      (defun try-find-best-root (base-dir buffer-dir current)
        (cond
         (base-dir ;; traverse until we reach the base
          (try-find-best-root (cdr base-dir) (cdr buffer-dir)
                              (append current (list (car buffer-dir)))))

         (buffer-dir ;; try until we hit the current directory
          (let* ((next-dir (append current (list (car buffer-dir))))
                 (file-file (concat (dir-list-to-path next-dir) "/" init-file)))
            (if (file-exists-p file-file)
                (dir-list-to-path current)
              (try-find-best-root nil (cdr buffer-dir) next-dir))))

         (t nil)))

      (let* ((buffer-dir (expand-file-name (file-name-directory (buffer-file-name buf))))
             (vc-root-dir (vc-find-root buffer-dir repo-file)))
        (if (and init-file vc-root-dir)
            (try-find-best-root
             (make-dir-list (expand-file-name vc-root-dir))
             (make-dir-list buffer-dir)
             '())
          vc-root-dir))) ;; default to vc root if init file not given

    ;; And some customizations
    (defvar vcs-root-sentinel ".git")
    (defvar python-module-sentinel "__init__.py")

    ;; This function sets how project root is determined
    (defun current-buffer-project-root ()
      (get-project-root-with-file
       (current-buffer) vcs-root-sentinel python-module-sentinel))

    (defun jedi-config:setup-server-args ()
      ;; little helper macro for building the arglist
      (defmacro add-args (arg-list arg-name arg-value)
        `(setq ,arg-list (append ,arg-list (list ,arg-name ,arg-value))))
      ;; and now define the args
      (let ((project-root (current-buffer-project-root))
            (active-venv (get-active-virtualenv)))
        (make-local-variable 'jedi:server-args)

        (when project-root
          (message (format "Adding system path: %s" project-root))
          (add-args jedi:server-args "--sys-path" project-root))

        (when (and jedi-config:add-system-virtualenv active-venv)
          (message (format "Adding system virtualenv: %s" active-venv))
          (add-args jedi:server-args "--virtual-env" active-venv))))

    ;; Use system python
    (defun jedi-config:maybe-use-system-python ()
      (when jedi-config:use-system-python
        (set-exec-path-from-shell-PATH)
        (make-local-variable 'jedi:server-command)
        (set 'jedi:server-command
             (list (executable-find "python") ;; may need help if running from GUI
                   (cadr default-jedi-server-command)))))

    ;; Now hook everything up
    ;; Hook up to autocomplete
    (add-to-list 'ac-sources 'ac-source-jedi-direct)

    ;; Global options
    ;; Don't let tooltip show up automatically
    (setq jedi:get-in-function-call-delay 10000000)

    ;; Enable Jedi setup on mode start
    (add-hook 'python-mode-hook 'jedi:setup)

    ;; Buffer-specific server options
    (add-hook 'python-mode-hook
              (lambda ()
                (jedi-config:setup-server-args)
                (jedi-config:maybe-use-system-python)))

    ;; And custom keybindings
    (add-hook 'python-mode-hook
              '(lambda ()
                 (local-set-key (kbd "M-.") 'jedi:goto-definition)
                 (local-set-key (kbd "M-,") 'jedi:goto-definition-pop-marker)
                 (local-set-key (kbd "M-?") 'jedi:show-doc)
                 (local-set-key (kbd "M-/") 'jedi:get-in-function-call)))
    ))
