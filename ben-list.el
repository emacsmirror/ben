;;; ben-list.el --- Manage ben sessions -*- lexical-binding: t -*-

;; Copyright (c) 2026 Sergio Pastor Pérez <sergio.pastorperez@gmail.com>

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

;; This is an interface to manage `ben' async processes.

;;; Code:

;;;; Requirements

(require 'ben)
(require 'vtable)
(require 'proced)

;;; ---

(defcustom ben-list-display-buffer-action
  nil
  "The action used to display the ben list buffer."
  :group 'ben
  :type 'sexp)

(defun ben-list--get-processes ()
  "Return processes started by `ben'."
  (let (table)
    (maphash (lambda (key val)
               (let ((proc (alist-get 'process val))
                     (subscribed (seq-filter (lambda (buf)
                                               (and (buffer-live-p buf)
                                                    (not (minibufferp buf))))
                                             (alist-get 'subscribed val))))
                 (push `((process . ,proc) (path . ,key) (subscribed . ,subscribed))
                       table)))
             ben--processes)
    (or table
        '(()))))

;; NOTE: the default face sets a foreground. Better to use one without so we can
;; propertize.
(defface ben-list-even-face `((t :extend t))
  "Face used by `ben-list-processes' for odd rows."
  :group 'ben)

(defface ben-list-odd-face '((t :background "gray92" :extend t))
  "Face used by `ben-list-processes' for odd rows."
  :group 'ben)

(defface ben-list-pid-face '((t :inherit bold))
  "Face used by `ben-list-processes' for odd rows."
  :group 'ben)

(defface ben-list-path-face '((t :inherit link))
  "Face used by `ben-list-processes' for odd rows."
  :group 'ben)

(defface ben-list-subscribed-face '((t :foreground "OliveDrab"))
  "Face used by `ben-list-processes' for odd rows."
  :group 'ben)

(defcustom ben-list-auto-update-flag t
  "Non-nil means auto update ben buffers."
  :group 'ben
  :type 'boolean)

(defcustom ben-list-auto-update-interval 0.5
  "Time interval in idle seconds for auto updating `ben' buffers."
  :group 'ben
  :type 'integer)

(defvar ben-list-auto-update-timer nil
  "Stores if `Ben' auto update timer is already installed.")

(defun ben-list-auto-update ()
  "Auto-update `ben' buffers using `run-at-time'.

If there are no `ben' buffers, cancel the timer."
  (if (and ben-list-auto-update-flag
           (get-buffer "*ben-processes*"))
      (ben-list-refresh)
    (cancel-timer ben-list-auto-update-timer)
    (setq ben-list-auto-update-timer nil)))

(defun ben-list--object-find ()
  "Find item of vtable under point."
  (interactive)
  (let ((col (vtable-current-column)))
    (cond
     ((eql col 0)
      (let* ((key 'pid)
             (pid (save-excursion
                    ;; HACK: indentation messes up with `thing-at-point'.
                    (when (zerop (current-column))
                      (forward-char))
                    (thing-at-point 'number t)))
             (grammar (assq key proced-grammar-alist))
             (refiner (nth 7 grammar)))
        (when refiner
          (proced)
          (proced-toggle-tree t)
          (add-to-list 'proced-refinements (list refiner pid key grammar) t)
          (print proced-refinements)
          (proced-update))))
     ((eql col 1) (dired (thing-at-point 'filename t)))
     ((eql col 2) (when-let* ((name (thing-at-point 'symbol t))
                              (buf (get-buffer name)))
                    (pop-to-buffer buf))))))

(defun ben-list-kill-process ()
  "Kill process under POINT."
  (interactive)
  (when-let* ((table (vtable-current-table))
              (obj (vtable-current-object))
              (proc (alist-get 'process obj))) ; This ensures the empty entry is not deleted.
    (kill-process proc)
    ;; NOTE: prevent the table from being empty so it doesn't get automatically
    ;; deleted.
    (if (eql (length (vtable-objects table)) 1)
        (vtable-update-object table '(()) obj)
      (vtable-remove-object table obj))))

(defun ben-list-refresh (&rest _)
  "Refresh `ben' process list."
  (interactive)
  ;; HACK: running this while on minibuffer resets `window-point'.
  (unless (minibufferp)
    (when-let* ((buf (get-buffer "*ben-processes*")))
      (with-current-buffer buf
        (let* ((windows (get-buffer-window-list buf))
               (win-and-pts (mapcar (lambda (win)
                                      (cons win (window-point win)))
                                    windows)))
          (goto-char (point-min))
          (when (vtable-current-table)
            (vtable-revert-command))

          (dolist (wp win-and-pts)
            (set-window-point (car wp) (cdr wp))))))))

(defvar-keymap ben-list-mode-map
  :doc "Keymap used in `ben-list-mode'."
  "n" #'next-line
  "p" #'previous-line
  "k" #'ben-list-kill-process
  "RET" #'ben-list--object-find)

(define-derived-mode ben-list-mode special-mode "ben processes"
  "Mode for displaying `ben' processes.

Type \\[ben-list-toggle-auto-update] to automatically update the
process list.  The time interval for updates can be configured
via `ben-list-auto-update-interval'."
  :interactive nil
  ;; HACK: since `ben-list--object-action' deals with buffers as symbols
  ;; using `thing-at-point'. The '.' should be considered as part of a
  ;; symbol.
  (modify-syntax-entry ?. "_")

  (setq buffer-read-only t)
  (setq-local revert-buffer-function #'ben-list-refresh)

  (if (and ben-list-auto-update-flag
           ben-list-auto-update-interval
           (not ben-list-auto-update-timer))
      (setq ben-list-auto-update-timer
            (run-with-idle-timer ben-list-auto-update-interval t
                                 #'ben-list-auto-update))))

;;;###autoload
(defun ben-list-processes ()
  "Open list of `ben' started processes."
  (interactive)
  (with-current-buffer (get-buffer-create "*ben-processes*")
    (let ((inhibit-read-only t))
      (ben-list-mode)
      (erase-buffer)
      (make-vtable
       :columns
       '((:name "PID" :min-width 3 :getter (lambda (obj table)
                                             (when obj
                                               (when-let ((proc (alist-get 'process obj)))
                                                 (number-to-string (process-id proc))))))
         (:name "Path" :min-width 4 :getter (lambda (obj table)
                                              (when obj
                                                (when-let ((path (alist-get 'path obj)))
                                                  path))))
         (:name "Buffers" :min-width 7 :getter (lambda (obj table)
                                                 (when obj
                                                   (when-let ((buffers (alist-get 'subscribed obj)))
                                                     buffers)))))
       :objects-function #'ben-list--get-processes
       :formatter (lambda (value column &rest _)
                    (if value
                        (cond
                         ((= column 0)
                          (propertize value 'face 'ben-list-pid-face))
                         ((= column 1)
                          (propertize value
                                      'face 'ben-list-path-face))
                         ((= column 2)
                          (propertize (string-join (mapcar (lambda (buf)
                                                             (buffer-name buf))
                                                           value)
                                                   ", ")
                                      'face 'ben-list-subscribed-face)))
                      " "))
       :separator-width 2
       :row-colors '(ben-list-even-face ben-list-odd-face)
       :keymap
       (define-keymap
                "g" #'ben-list-refresh))
      (pop-to-buffer (current-buffer) ben-list-display-buffer-action))))

(provide 'ben-list)

;;; ben-list.el ends here
