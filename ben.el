;;; ben.el --- Support for `direnv' that operates buffer-locally  -*- lexical-binding: t; -*-

;; Copyright (C) 2020  Steve Purcell
;; Copyright (c) 2026 Sergio Pastor Pérez <sergio.pastorperez@gmail.com>

;; Author: Steve Purcell <steve@sanityinc.com>
;;         Sergio Pastor Pérez <sergio.pastorperez@gmail.com>
;; Keywords: processes, tools
;; Homepage: https://codeberg.org/pastor/ben.el
;; Package-Requires: ((emacs "29.1") (inheritenv "0.1") (seq "2.24"))
;; Package-Version: 0.12.3

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Use direnv (https://direnv.net) to set environment variables on a
;; per-buffer basis.  This means that when you work across multiple
;; projects which have `.envrc` files, all processes launched from the
;; buffers "in" those projects will be executed with the environment
;; variables specified in those files.  This allows different versions
;; of linters and other tools to be installed in each project if
;; desired.

;; Enable `ben-global-mode' late in your startup files.  For
;; interaction with this functionality, see `ben-mode-map', and the
;; commands `ben-reload', `ben-allow' and `ben-deny'.

;; In particular, you can enable keybindings for the above commands by
;; binding your preferred prefix to `ben-command-map' in
;; `ben-mode-map', e.g.

;;    (with-eval-after-load 'ben
;;      (define-key ben-mode-map (kbd "C-c e") 'ben-command-map))

;;; Code:

;; TODO: special handling for DIRENV_* vars? exclude them? use them to safely reload more aggressively?
;; TODO: handle nil default-directory (rarely happens, but is possible)
;; TODO: limit size of *direnv* buffer
;; TODO: special handling of compilation-environment?
;; TODO: handle use of "cd" and other changes of `default-directory' in a buffer over time?
;; TODO: handle "allow" asynchronously?
;; TODO: describe env
;; TODO: click on mode lighter to get details
;; TODO: handle when direnv is not installed?
;; TODO: provide a way to disable in certain projects?
;; TODO: cleanup the cache?

(require 'seq)
(require 'json)
(require 'subr-x)
(require 'ansi-color)
(require 'cl-lib)
(require 'diff-mode) ; for its faces
(require 'inheritenv)
(eval-when-compile (require 'tramp))

;;; Custom vars and minor modes

(defgroup ben nil
  "Apply per-buffer environment variables using the direnv tool."
  :group 'processes)

(defcustom ben-debug nil
  "Whether or not to output debug messages while in operation.
Messages are written into the *ben-debug* buffer."
  :type 'boolean)

(defcustom ben-add-to-mode-line-misc-info t
  "When non-nil, append the ben indicator to the mode line.
Experienced users can set this to a nil value and then include the
`ben-indicator' anywhere they want in `mode-line-format' or related."
  :group 'ben
  :type 'boolean)

(defcustom ben-async-processing t
  "Whether or not to update the environment asynchronously."
  :group 'ben
  :type 'boolean)

(defcustom ben-async-prompt-before-kill t
  "Whether or not to prompt the user before killing running ben processes."
  :group 'ben
  :type 'boolean)

(defcustom ben-status-frames '("=  " "== " "===" " ==" "  =" "   ")
  "List of frames for the spinner."
  :group 'ben
  :type '(repeat string))

(defcustom ben-update-on-eshell-directory-change t
  "Whether ben will update environment when changing directory in eshell."
  :type 'boolean)

(defcustom ben-show-summary-in-minibuffer t
  "When non-nil, show a summary of the changes made by direnv in the minibuffer."
  :group 'ben
  :type 'boolean)

(defcustom ben-disable-in-minibuffer nil
  "Whether or not to load environments in the minibuffer.

A non-nil value will prevent the envrionment from propagating into the
minibuffer.  Note that `completing-read' will not provide completion
using the new environment."
  :group 'ben
  :type 'boolean)

(defcustom ben-direnv-executable "direnv"
  "The direnv executable used by ben."
  :type 'string)

(define-obsolete-variable-alias 'ben--lighter 'ben-indicator "2021-05-17")

(defcustom ben-indicator '(" ben[" (:eval (ben--status)) "]")
  "The mode line lighter for `ben-mode'.
You can set this to nil to disable the lighter."
  :type 'sexp)
(put 'ben-indicator 'risky-local-variable t)

(defcustom ben-none-indicator '((:propertize "none" face ben-mode-line-none-face))
  "Construct spec used by the default `ben-indicator' when ben is inactive."
  :type 'sexp)

(defcustom ben-on-indicator '((:propertize "on" face ben-mode-line-on-face))
  "Construct spec used by the default `ben-indicator' when ben is on."
  :type 'sexp)

(defcustom ben-denied-indicator '((:propertize "denied" face ben-mode-line-denied-face))
  "Construct spec used by the default `ben-indicator' when ben is blocked."
  :type 'sexp)

(defcustom ben-error-indicator '((:propertize "error" face ben-mode-line-error-face))
  "Construct spec used by the default `ben-indicator' when ben has errored."
  :type 'sexp)

(defcustom ben-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") 'ben-allow)
    (define-key map (kbd "d") 'ben-deny)
    (define-key map (kbd "r") 'ben-reload)
    (define-key map (kbd "l") 'ben-show-log)
    map)
  "Keymap for commands in `ben-mode'.
See `ben-mode-map' for how to assign a prefix binding to these."
  :type '(restricted-sexp :match-alternatives (keymapp)))
(fset #'ben-command-map ben-command-map)

(defcustom ben-mode-map (make-sparse-keymap)
  "Keymap for `ben-mode'.
To access this map, give it a prefix keybinding.

Example:
  (define-key ben-mode-map (kbd \"C-c e\") \\='ben-command-map)"
  :type '(restricted-sexp :match-alternatives (keymapp)))

(defcustom ben-remote nil
  "Whether or not to enable direnv over TRAMP."
  :type 'boolean)

(defcustom ben-supported-tramp-methods '("ssh")
  "Tramp connection methods that are supported by ben."
  :type '(repeat string))

(defvar ben--used-mode-line-construct nil
  "Mode line construct last added by `notmuch-indicator-mode'.")

;;;###autoload
(define-minor-mode ben-mode
  "A local minor mode in which env vars are set by direnv."
  :init-value nil
  :lighter 'ben
  :keymap ben-mode-map
  (if ben-mode
      (progn
        (when ben-add-to-mode-line-misc-info
          (setq ben--used-mode-line-construct ben-indicator)
          ;; NOTE since this is a minor mode, `mode-line-misc-info' needs to be
          ;; controlled locally.
          (make-local-variable 'mode-line-misc-info)
          (add-to-list 'mode-line-misc-info ben-indicator))
        (ben--update)
        (when (and (derived-mode-p 'eshell-mode) ben-update-on-eshell-directory-change)
          (add-hook 'eshell-directory-change-hook #'ben--update nil t)))
    (setq mode-line-misc-info (delete ben--used-mode-line-construct mode-line-misc-info))
    (ben--clear (current-buffer))
    (remove-hook 'eshell-directory-change-hook #'ben--update t)))

;;;###autoload
(define-globalized-minor-mode ben-global-mode ben-mode
  (lambda ()
    (when
        (cond
         ((and (minibufferp) ben-disable-in-minibuffer) nil)
         ((file-remote-p default-directory)
          (and ben-remote
               (seq-contains-p
                ben-supported-tramp-methods
                (with-parsed-tramp-file-name default-directory vec vec-method))))
         (t (executable-find ben-direnv-executable)))
      (ben-mode 1)))
  :predicate t)

(defface ben-mode-line-on-face '((t :inherit success))
  "Face used in mode line to indicate that direnv is in effect.")

(defface ben-mode-line-denied-face '((t :inherit shadow))
  "Face used in mode line to indicate that direnv blocking env.")

(defface ben-mode-line-error-face '((t :inherit error))
  "Face used in mode line to indicate that direnv failed.")

(defface ben-mode-line-none-face '((t :inherit warning))
  "Face used in mode line to indicate that direnv is not active.")

(defface ben-mode-line-loading-face '((t :inherit mode-line-emphasis))
  "Face used in mode line to indicate that direnv is loading the environment.")

;;; Global state

(defvar ben--cache (make-hash-table :test 'equal :size 10)
  "Known ben directories and their direnv results.
The values are as produced by `ben--export'.")

(defvar ben--processes (make-hash-table :test 'equal :size 10)
  "Asynchonous processes started by ben.
Each entry uses an environment directory as key.

Each value of this table is an alist of
`((process . <process>) (subscribed . (buf_0 buf_1 ... buf_n)))'

The SUBSCRIBED field allows subscribing buffers to have the new
environment applied once the async process finishes.")

;;; Local state

(defvar-local ben--status 'none
  "Symbol indicating state of the current buffer's direnv.
One of \\='(none loading on error).")

(defvar-local ben--remote-path nil
  "Buffer local variable for remote path.
If set, this will override `tramp-remote-path' via connection
local variables.")

;;; Internals

(defvar ben--status-timer nil
  "Timer for updating the spinner.")

(defvar ben--status-index 0
  "Current index in the spinner frames list.")

(defvar ben--loading-indicator nil
  "Current frame to display during the loading indicator state.")

(defun ben--status ()
  "Get the propertized status to display in the mode line."
  (pcase ben--status
    (`none ben-none-indicator)
    (`loading ben--loading-indicator)
    (`on ben-on-indicator)
    (`denied ben-denied-indicator)
    (`error ben-error-indicator)))

(defvar ben--loading-buf-list '()
  "List of buffers that are loading an environment.")

(defun ben--status-update-buf (buf)
  "Update the spinner in BUF's mode line."
  (with-current-buffer buf
    (let ((loading-environments (hash-table-keys ben--processes))
          (buf-env-dir (ben--find-env-dir)))
      (cond
       ((member buf-env-dir loading-environments)
        (let ((spinner (nth ben--status-index ben-status-frames)))
          (setq ben--loading-indicator `((:propertize ,spinner face ben-mode-line-loading-face))
                ben--status 'loading)))
       ((and (not buf-env-dir)
             (equal ben--status 'loading))
        (setq ben--status 'none))))
    (force-mode-line-update)))

(defun ben-status-update ()
  "Update the spinner in the mode line."
  (setq ben--status-index
        (mod (1+ ben--status-index)
             (length ben-status-frames)))
  (walk-windows (lambda (win)
                  (let ((buf (window-buffer win)))
                    (unless (minibufferp buf)
                      (ben--status-update-buf buf))))))

(defun ben-status-start ()
  "Start the spinner and update it periodically."
  (unless ben--status-timer
    (setq ben--status-index 0)
    (setq ben--status-timer
          (run-with-timer 0 0.1 #'ben-status-update))))

(defun ben-status-stop (env-dir)
  "Stop the spinner and remove it from the mode line.
ENV-DIR is the directory where to update the status."
  (when ben--status-timer
    (cancel-timer ben--status-timer)
    (setq ben--status-timer nil))
  (let ((status ben--status))
    (dolist (buf (ben--mode-buffers))
      (with-current-buffer buf
        (let* ((buf-env-dir (ben--find-env-dir))
               (status* (cond
                         ((equal buf-env-dir env-dir)
                          status)
                         ((and (not buf-env-dir)
                               (equal ben--status 'loading))
                          'none)
                         (t status))))
          (setq ben--status status*)
          (force-mode-line-update))))))

(defun ben--env-dir-p (dir)
  "Return non-nil if DIR contains a config file for direnv."
  (or
   (file-exists-p (expand-file-name ".envrc" dir))
   (file-exists-p (expand-file-name ".env" dir))))

(defun ben--find-env-dir ()
  "Return the ben directory for the current buffer, if any.
This is based on a file scan.  In most cases we prefer to use the
cached list of known directories.

Regardless of buffer file name, we always use
`default-directory': the two should always match, unless the user
called `cd'"
  (let ((env-dir (locate-dominating-file default-directory #'ben--env-dir-p)))
    (when env-dir
      ;; `locate-dominating-file' appears to sometimes return abbreviated paths, e.g. with ~
      (setq env-dir (expand-file-name env-dir)))
    env-dir))

(defun ben--find-deny-hash (env-dir)
  "Return the ben file hash from ENV-DIR."
  (when-let* ((file-path (or (expand-file-name ".envrc" env-dir)
                             (expand-file-name ".env" env-dir)))
              (contents (with-temp-buffer
                          (insert file-path "\n")
                          (buffer-string))))
    (secure-hash 'sha256 contents)))

(defun ben--denied-p (env-dir)
  "Return TRUE if ENV-DIR is blocked."
  (let ((deny-hash (ben--find-deny-hash env-dir))
        (deny-path (concat (or (getenv "XDG_DATA_HOME")
                               (concat (getenv "HOME") "/.local/share"))
                           "/direnv/deny")))
    (locate-file deny-hash
                 (list deny-path))))

(defun ben--cache-key (env-dir process-env)
  "Get a hash key for the result of invoking direnv in ENV-DIR with PROCESS-ENV.
PROCESS-ENV should be the environment in which direnv was run,
since its output can vary according to its initial environment."
  (string-join (cons env-dir process-env) "\0"))

(defun ben--update-async ()
  "Update the current buffer's env asynchronously if it is managed by direnv.
All ben.el-managed buffers with this env will have their
environments updated."
  (let* ((cur-buf (current-buffer))
         (env-dir (ben--find-env-dir))
         (cache-key (ben--cache-key env-dir (default-value 'process-environment)))
         (cache (gethash cache-key ben--cache))
         (update-callback
          (lambda (env)
            (unless cache
              (puthash cache-key env ben--cache))
            (unwind-protect
                (when (buffer-live-p cur-buf)
                  (ben--apply cur-buf env))
              (let ((subscribed (alist-get 'subscribed (gethash env-dir ben--processes))))
                (dolist (buf subscribed)
                  (when (buffer-live-p buf)
                    (ben--apply buf env))))))))
    (if env-dir
        (if cache
            (funcall update-callback cache)
          (let ((running-process (alist-get 'process (gethash env-dir ben--processes)))
                (subscribed (alist-get 'subscribed (gethash env-dir ben--processes))))
            (if running-process
                (progn
                  (unless (memq cur-buf subscribed)
                    (push cur-buf subscribed))
                  (puthash env-dir
                           `((process . ,running-process)
                             (subscribed . ,subscribed))
                           ben--processes))
              (ben--export-async update-callback env-dir))))
      (funcall update-callback 'none))))

(defun ben--update-sync ()
  "Update the current buffer's env synchronously if it is managed by direnv.
All ben.el-managed buffers with this env will have their
environments updated."
  (let* ((env-dir (ben--find-env-dir))
         (result
          (if env-dir
              (let ((cache-key (ben--cache-key env-dir (default-value 'process-environment))))
                (pcase (gethash cache-key ben--cache 'missing)
                  (`missing (let ((calculated (ben--export env-dir)))
                              (puthash cache-key calculated ben--cache)
                              calculated))
                  (cached cached)))
            'none)))
    (ben--apply (current-buffer) result)))

(defun ben--update ()
  "Update the current buffer's environment if it is managed by direnv.
All ben.el-managed buffers with this env will have their
environments updated.
Synchronously or asynchronously according to the value of
`ben-async-processing'."
  (if ben-async-processing
      (ben--update-async)
    (ben--update-sync)))

(defmacro ben--at-end-of-special-buffer (name &rest body)
  "At the end of `special-mode' buffer NAME, execute BODY.
To avoid confusion, `ben-mode' is explicitly disabled in the buffer."
  (declare (indent 1))
  `(with-current-buffer (get-buffer-create ,name)
     (unless (derived-mode-p 'special-mode)
       (special-mode))
     (when ben-mode (ben-mode -1))
     (goto-char (point-max))
     (let ((inhibit-read-only t))
       ,@body)))

(defun ben--debug (msg &rest args)
  "A version of `message' which does nothing if `ben-debug' is nil.
MSG and ARGS are as for that function."
  (when ben-debug
    (ben--at-end-of-special-buffer "*ben-debug*"
      (insert (apply #'format msg args))
      (newline))))

(defun ben--summarise-changes (items)
  "Create a summary string for ITEMS."
  (if items
      (cl-loop for (name . val) in items
               with process-environment = (default-value 'process-environment)
               unless (string-prefix-p "DIRENV_" name)
               collect (cons name
                             (if val
                                 (if (getenv name)
                                     '("~" diff-changed)
                                   '("+" diff-added))
                               '("-" diff-removed)))
               into entries
               finally return (cl-loop for (name prefix face) in (seq-sort-by 'car 'string< entries)
                                       collect (propertize (concat prefix name) 'face face) into strings
                                       finally return (string-join strings " ")))
    "no changes"))

(defun ben--show-summary (result directory)
  "Summarise successful RESULT in the minibuffer.
DIRECTORY is the directory in which the environment changes."
  (message "direnv: %s %s"
           (ben--summarise-changes result)
           (propertize (concat "(" (abbreviate-file-name (directory-file-name directory)) ")")
                       'face 'font-lock-comment-face)))

(defun ben--export-async (callback env-dir)
  "Export the env vars for ENV-DIR using direnv.
Return value is either \\='error, \\='none, or an alist of environment
variable names and values.

CALLBACK the function which will get the return value."
  (let* ((default-directory env-dir)
         (stdout (generate-new-buffer "*ben-export*"))
         (stderr (generate-new-buffer "*ben-export-stderr*"))
         (export-callback
          (lambda (exit-code)
            (unless (ben--env-dir-p env-dir)
              (error "%s is not a directory with a .envrc" env-dir))
            (message "Running direnv in %s ..." env-dir)
            (let (result)
              (with-current-buffer stdout
                (ben--debug "Direnv exited with %s and stderr=%S, stdout=%S"
                            exit-code
                            (with-current-buffer stderr
                              (buffer-string))
                            (buffer-string))
                (cond ((eq 0 exit-code) ;; zerop is not an option, as exit-code may sometimes be a symbol
                       (progn
                         (if (zerop (buffer-size))
                             (setq result 'none)
                           (goto-char (point-min))
                           (prog1
                               (if (ben--denied-p env-dir)
                                   (setq result 'denied)
                                 (setq result (let ((json-key-type 'string)) (json-read-object))))
                             (when ben-show-summary-in-minibuffer
                               (ben--show-summary result env-dir))))))
                      ((eq 9 exit-code)
                       (message "Direnv killed in %s" env-dir)
                       (if (ben--denied-p env-dir)
                           (setq result 'denied)
                         (setq result 'error)))
                      (t
                       (message "Direnv failed in %s" env-dir)
                       (setq result 'error)))
                (ben--at-end-of-special-buffer "*ben*"
                  (insert "──── " (format-time-string "%F %T") " ──── " env-dir " ────\n\n")
                  (let ((initial-pos (point))
                        ansi-color-context)
                    (insert (with-current-buffer stderr
                              (ansi-color-apply (buffer-string))))
                    (goto-char (point-max))
                    (add-face-text-property initial-pos (point) (if (eq 0 exit-code) 'success 'error)))
                  (insert "\n\n")
                  ;; Since the async processing interface allows the user to
                  ;; interactively kill the process, do not popup the buffer
                  ;; when `ben-async-processing' is true.
                  (when (and (numberp exit-code) (and (/= 0 exit-code)
                                                      (/= 9 exit-code)))
                    (display-buffer (current-buffer)))))
              (kill-buffer stdout)
              (kill-buffer stderr)
              result)))
         (sentinel (lambda (process msg)
                     (funcall callback
                              (funcall export-callback
                                       (ben--async-process-sentinel process msg))))))
    (ben--start-process-with-global-env sentinel stdout stderr ben-direnv-executable "export" "json")))

(defun ben--export (env-dir)
  "Export the env vars for ENV-DIR using direnv.
Return value is either \\='error, \\='none, or an alist of environment
variable names and values."
  (unless (ben--env-dir-p env-dir)
    (error "%s is not a directory with a .envrc" env-dir))
  (message "Running direnv in %s ... (C-g to abort)" env-dir)
  (let ((stderr-file (make-temp-file "ben"))
        result)
    (unwind-protect
        (let ((default-directory env-dir))
          (with-temp-buffer
            (let ((exit-code (condition-case nil
                                 (ben--call-process-with-global-env ben-direnv-executable nil (list t stderr-file) nil "export" "json")
                               (quit
                                (message "interrupted!!")
                                'interrupted))))
              (ben--debug "Direnv exited with %s and stderr=%S, stdout=%S"
                          exit-code
                          (with-temp-buffer
                            (insert-file-contents stderr-file)
                            (buffer-string))
                          (buffer-string))
              (cond ((eq 0 exit-code) ;; zerop is not an option, as exit-code may sometimes be a symbol
                     (progn
                       (if (zerop (buffer-size))
                           (setq result 'none)
                         (goto-char (point-min))
                         (prog1
                             (if (ben--denied-p env-dir)
                                 (setq result 'denied)
                               (setq result (let ((json-key-type 'string)) (json-read-object))))
                           (when ben-show-summary-in-minibuffer
                             (ben--show-summary result env-dir))))))
                    ((eq 9 exit-code)
                     (message "Direnv killed in %s" env-dir)
                     (if (ben--denied-p env-dir)
                         (setq result 'denied)
                       (setq result 'error)))
                    (t
                     (message "Direnv failed in %s" env-dir)
                     (setq result 'error)))
              (ben--at-end-of-special-buffer "*ben*"
                (insert "──── " (format-time-string "%F %T") " ──── " env-dir " ────\n\n")
                (let ((initial-pos (point)))
                  (insert-file-contents stderr-file)
                  (goto-char (point-max))
                  (let (ansi-color-context)
                    (ansi-color-apply-on-region initial-pos (point)))
                  (add-face-text-property initial-pos (point) (if (eq 0 exit-code) 'success 'error)))
                (insert "\n\n")
                (when (and (numberp exit-code) (/= 0 exit-code))
                  (display-buffer (current-buffer)))))))
      (delete-file stderr-file))
    result))

;; Forward declarations for the byte compiler
(defvar eshell-path-env)
(defvar Info-directory-list)

(defun ben--merged-environment (process-env pairs)
  "Make a `process-environment' value that merges PROCESS-ENV with PAIRS.
PAIRS is an alist obtained from direnv's output.
Values from PROCESS-ENV will be included, but their values will
be masked by Emacs' handling of `process-environment' if they
also appear in PAIRS."
  (append (mapcar (lambda (pair)
                    (if (cdr pair)
                        (format "%s=%s" (car pair) (cdr pair))
                      ;; Plain env name is the syntax for unsetting vars
                      (car pair)))
                  pairs)
          process-env))

(defun ben--clear (buf)
  "Remove any effects of `ben-mode' from BUF."
  (with-current-buffer buf
    (kill-local-variable 'exec-path)
    (kill-local-variable 'process-environment)
    (kill-local-variable 'Info-directory-list)
    (when (derived-mode-p 'eshell-mode)
      (if (fboundp 'eshell-set-path)
          (eshell-set-path (butlast exec-path))
        (kill-local-variable 'eshell-path-env)))))


(defun ben--apply (buf result)
  "Update BUF with RESULT, which is a result of `ben--export'."
  (with-current-buffer buf
    (setq-local ben--status (if (listp result) 'on result))
    (ben--clear buf)
    (if (memq result '(none error denied))
        (progn
          (ben--debug "[%s] reset environment to default" buf))
      (ben--debug "[%s] applied merged environment" buf)
      (let* ((remote (when-let* ((fn (buffer-file-name buf)))
                       (file-remote-p fn)))
             (env (ben--merged-environment
                   (default-value (if remote
                                      'tramp-remote-process-environment
                                    'process-environment))
                   result))
             (path (getenv-internal "PATH" env))
             (parsed-path (parse-colon-path path)))
        (if remote
            (setq-local tramp-remote-process-environment env)
          (setq-local process-environment env))
        ;; Get PATH from the merged environment: direnv may not have changed it
        (if remote
            (setq-local ben--remote-path parsed-path)
          (setq-local exec-path parsed-path))
        (cond ((derived-mode-p 'eshell-mode)
               (if (fboundp 'eshell-set-path)
                   (eshell-set-path path)
                 (setq-local eshell-path-env path)))
              ((derived-mode-p 'Info-mode)
               (when-let* ((info-path (getenv-internal "INFOPATH" env)))
                 (setq-local Info-directory-list
                             (append (seq-filter #'identity (parse-colon-path info-path))
                                     (default-value 'Info-directory-list))))))))))

(defun ben--update-env (env-dir)
  "Refresh the state of the direnv in ENV-DIR and apply in all relevant buffers."
  (ben--debug "Invalidating cache for env %s" env-dir)
  (cl-loop for k being the hash-keys of ben--cache
           if (string-prefix-p (concat env-dir "\0") k)
           do (remhash k ben--cache))
  (ben--debug "Refreshing all buffers in env  %s" env-dir)
  (dolist (buf (ben--mode-buffers))
    (with-current-buffer buf
      (when (string= (ben--find-env-dir) env-dir)
        (ben--update)))))

(defun ben--mode-buffers ()
  "Return a list of all live buffers in which `ben-mode' is enabled."
  (seq-filter (lambda (b) (and (buffer-live-p b)
                               (with-current-buffer b
                                 ben-mode)))
              (buffer-list)))

(defmacro ben--with-required-current-env (varname &rest body)
  "With VARNAME set to the current env dir path, execute BODY.
If there is no current env dir, abort with a user error."
  (declare (indent 1))
  (cl-assert (symbolp varname))
  `(let ((,varname (ben--find-env-dir)))
     (unless ,varname
       (user-error "No enclosing .envrc"))
     ,@body))

(defun ben--call-process-with-global-env (&rest args)
  "Like `call-process', but always use the global process environment.
In particular, we ensure the default variable `exec-path' and
`process-environment' are used.  This ensures an .envrc doesn't take
`ben-direnv-executable' out of our path.
ARGS is as for `call-process'."
  (let ((exec-path (default-value 'exec-path))
        (process-environment (default-value 'process-environment)))
    (apply #'process-file args)))

(defun ben--start-process-with-global-env (sentinel out-buf err-buf &rest args)
  "Like `start-process', but always use the global process environment.
In particular, we ensure the default variable `exec-path' and
`process-environment' are used.  This ensures an .envrc doesn't take
`ben-direnv-executable' out of our path.

SENTINEL, OUT-BUF, ERR-BUF and ARGS are the respective keywords of
`make-process'."
  (let* ((env-buf (current-buffer))
         (env-dir default-directory)
         (running-process (alist-get 'process (gethash env-dir ben--processes)))
         (wrapped-sentinel (lambda (process msg)
                             (unless (buffer-live-p env-buf)
                               ;; Migrate to any buffer from the same env.
                               (setq env-buf
                                     (seq-find (lambda (buf)
                                                 (with-current-buffer buf
                                                   (equal (ben--find-env-dir) env-dir)))
                                               (ben--mode-buffers))))
                             (unwind-protect
                                 ;; NOTE: the call back and the status stop
                                 ;; should run in a buffer from the same
                                 ;; environment as the async process.
                                 (with-current-buffer env-buf
                                   (funcall sentinel process msg)
                                   (ben-status-stop env-dir))
                               (remhash env-dir ben--processes)))))
    (if running-process
        (ben--debug "Ignoring, process already running for %s." env-dir)
      (let* ((exec-path (default-value 'exec-path))
             (process-environment (default-value 'process-environment))
             (process (make-process
                       :name "*ben-process*"
                       :buffer out-buf
                       :stderr err-buf
                       :sentinel wrapped-sentinel
                       :connection-type 'pipe
                       :command args)))
        (puthash env-dir `((process . ,process)
                           (subscribed . (,(current-buffer))))
                 ben--processes)
        (when ben-add-to-mode-line-misc-info
          (ben-status-start))))))

(defun ben--kill-running-prompt (env-dir)
  "Prompt user to kill any process loading the environment of ENV-DIR."
  (when-let* ((proc (alist-get 'process (gethash env-dir ben--processes)))
              (kill (if ben-async-prompt-before-kill
                        (yes-or-no-p (format "Process %s is loading the environment, kill it? " proc))
                      t)))
    (kill-process proc)
    (while (alist-get 'process (gethash env-dir ben--processes))
      (sleep-for 0.1))))

(defun ben--run-direnv (verb)
  "Run direnv command named by VERB, then refresh current env."
  (ben--with-required-current-env env-dir
    (ben--kill-running-prompt env-dir)
    (let* ((outbuf (get-buffer-create (format "*ben-%s*" verb)))
           (default-directory env-dir)
           (exit-code (ben--call-process-with-global-env ben-direnv-executable nil outbuf nil verb)))
      (if (zerop exit-code)
          (progn
            (ben--update-env env-dir)
            (kill-buffer outbuf))
        (display-buffer outbuf)
        (user-error "Error running direnv %s" verb)))))

(defun ben-reload ()
  "Reload the current env."
  (interactive)
  (ben--run-direnv "reload"))

(defun ben--async-process-sentinel (process msg)
  "Return PROCESS's exit code.

Display MSG in debug buffer if `ben-debug' is non-nil."
  (when (memq (process-status process) '(exit signal))
    (let ((exit-code (process-exit-status process)))
      (ben--debug (concat (process-name process) " - " msg " - status: " (number-to-string exit-code)))
      exit-code)))

(defun ben-allow ()
  "Run \"direnv allow\" in the current env."
  (interactive)
  (ben--run-direnv "allow"))

(defun ben-deny ()
  "Run \"direnv deny\" in the current env."
  (interactive)
  (ben--run-direnv "deny"))

(defun ben-reload-all ()
  "Reload direnvs for all buffers.
This can be useful if a .envrc has been deleted."
  (interactive)
  (ben--debug "Invalidating cache for all envs")
  (clrhash ben--cache)
  (dolist (buf (ben--mode-buffers))
    (with-current-buffer buf
      (ben--update))))

(defun ben-show-log ()
  "Open ben log buffer."
  (interactive)
  (if-let* ((buffer (get-buffer "*ben*")))
      (pop-to-buffer buffer)
    (message "Ben log buffer does not exist")))


;;; Propagate local environment to commands that use temp buffers

(defun ben-propagate-environment (orig &rest args)
  "Advice function to wrap a command ORIG and make it use our local env.

This can be used to force compliance where ORIG starts processes
in a temp buffer.  ARGS is as for ORIG."
  (if ben-mode
      (inheritenv (apply orig args))
    (apply orig args)))

(defun ben-propagate-tramp-environment (buf)
  "Advice function to propagate environments to tramp.

This will affect `tramp-remote-path' and
`tramp-remote-process-environment' from buffer local values.
BUF is the buffer where to adjust the tramp variables."
  (when ben-mode
    (let ((cur-path ben--remote-path)
          (cur-env tramp-remote-process-environment))
      (with-current-buffer buf
        (setq-local tramp-remote-process-environment cur-env)
        (setq-local ben--remote-path cur-path))))
  buf)

(defun ben-get-remote-path (fn vec)
  "Advice wrap for FN `tramp-get-remote-path' with its argument VEC.

Shortcuts tramp caching direnv sets the variable `exec-path'."
  (with-current-buffer (tramp-get-connection-buffer vec)
    (or ben--remote-path
        (apply fn vec nil))))

;; NOTE: since this function is meant to be invoked by `completing-read',
;; `ben-mode' must be enabled in the minibuffer. This can be configured by
;; setting `ben-disable-in-minibuffer' to nil.
(advice-add #'Man-completion-table :around #'ben-propagate-environment)
(advice-add #'shell-command :around #'ben-propagate-environment)
(advice-add #'shell-command-to-string :around #'ben-propagate-environment)
(advice-add #'async-shell-command :around #'ben-propagate-environment)
(advice-add #'org-babel-eval :around #'ben-propagate-environment)
(advice-add #'org-export-file :around #'ben-propagate-environment)
(advice-add #'tramp-get-connection-buffer :filter-return #'ben-propagate-tramp-environment)
(advice-add #'tramp-get-remote-path :around #'ben-get-remote-path)


;;; Major mode for .envrc files

;; Generate direnv keywords with:
;;     $ rg "Usage:\s+([^_]\w+)" DIRENV_SRC/stdlib.sh -Nor '"$1"' | sort | uniq
(defvar ben-file-extra-keywords
  '("MANPATH_add" "PATH_add" "PATH_rm" "direnv_apply_dump" "direnv_layout_dir"
    "direnv_load" "direnv_version" "dotenv" "dotenv_if_exists"
    "env_vars_required" "expand_path" "fetchurl" "find_up" "has" "join_args"
    "layout" "load_prefix" "log_error" "log_status" "on_git_branch" "path_add"
    "path_rm" "rvm" "semver_search" "source_env" "source_env_if_exists"
    "source_up" "source_up_if_exists" "source_url" "strict_env" "unstrict_env"
    "use" "use_flake" "use_flox" "use_guix" "use_nix" "use_vim" "user_rel_path"
    "watch_dir" "watch_file")
  "Useful direnv keywords to be highlighted.")

(declare-function sh-set-shell "sh-script")

;;;###autoload
(define-derived-mode ben-file-mode
  sh-mode "ben"
  "Major mode for .envrc files as used by direnv.
\\{ben-file-mode-map}"
  (sh-set-shell "bash")
  (font-lock-add-keywords
   nil `((,(regexp-opt ben-file-extra-keywords 'symbols)
          (0 font-lock-keyword-face)))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.envrc\\'" . ben-file-mode))


(provide 'ben)
;;; ben.el ends here

;; LocalWords:  ben direnv

;; Local Variables:
;; coding: utf-8
;; indent-tabs-mode: nil
;; End:
