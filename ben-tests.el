;;; ben-tests.el --- Test suite for ben          -*- lexical-binding: t; -*-

;; Copyright (C) 2022  Steve Purcell
;; Copyright (c) 2026 Sergio Pastor Pérez <sergio.pastorperez@gmail.com>

;; Author: Steve Purcell <steve@sanityinc.com>
;; Keywords:

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

;; Just a few basic regression tests

;;; Code:

(require 'ben)
(require 'ert)
(require 'cl-lib)

(defgroup ben-tests nil "Ben.el tests." :group 'test)

(setq ben-debug t)



(defun ben-tests--exec (&rest args)
  "Helper function to run `ben-direnv-executable' with ARGS."
  (when ben-async-processing
    (sleep-for 0.1))
  (should (apply 'call-process ben-direnv-executable nil nil nil args)))

(defmacro ben-tests--with-extra-global-env-var (key val &rest body)
  "Temporarily set var KEY to VAL in the global `process-environment'.

The lexical environment applies only while BODY is evaluated."
  (declare (indent 2))
  (let ((old-env (gensym)))
    `(let ((,old-env (default-value 'process-environment)))
       (push (format "%s=%s" ,key ,val) (default-value 'process-environment))
       (unwind-protect
           (progn
             ,@body)
         (setq-default process-environment ,old-env)))))

(defmacro ben-tests--with-temp-directory (var &rest body)
  "Create a temporary directory, bind it to VAR, make it current, and execute BODY."
  (declare (indent 1))
  (let ((passed (gensym)))
    `(let* ((default-directory (make-temp-file "ben" t))
            (ben-debug t)
            ,passed
            (,var default-directory))
       (unwind-protect
           (progn
             (when (get-buffer "*ben-debug*")
               (kill-buffer "*ben-debug*"))
             ,@body
             (setq ,passed t))
         (unless ,passed
           (message "Debug output: %s"
                    (when (get-buffer "*ben-debug*")
                      (with-current-buffer "*ben-debug*" (buffer-string)))))))))

(ert-deftest ben-no-op ()
  "When there's no .envrc, do nothing."
  (ben-tests--with-temp-directory _
    (with-temp-buffer
      (ben-mode 1)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (eq ben--status 'none))
      (when ben-async-processing
        (sleep-for 0.1))
      (should (not (local-variable-p 'process-environment))))))



(ert-deftest ben-direnv-is-available ()
  "Check the executable is executable!"
  (when ben-async-processing
    (sleep-for 0.1))
  (should (executable-find ben-direnv-executable)))

(ert-deftest ben-no-op-unless-allowed ()
  "When the .envrc isn't allowed, do nothing."
  (ben-tests--with-temp-directory _
    (with-temp-file ".envrc"
      (insert "export FOO=BAR"))
    (with-temp-buffer
      (ben-mode 1)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (not (local-variable-p 'process-environment)))
      (when ben-async-processing
        (sleep-for 0.1))
      (should (eq ben--status 'error)))))

(ert-deftest ben-setting-propagates-when-mode-enabled ()
  "Pick up existing .envrc at mode startup."
  (ben-tests--with-temp-directory _
    (with-temp-file ".envrc"
      (insert "export FOO=BAR"))

    (ben-tests--exec "allow")

    (with-temp-buffer
      (ben-mode 1)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (local-variable-p 'process-environment))
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal "BAR" (getenv "FOO")))
      (when ben-async-processing
        (sleep-for 0.1))
      (should (eq ben--status 'on)))))

(ert-deftest ben-setting-propagates-when-allowed ()
  (ben-tests--with-temp-directory _
    (with-temp-file ".envrc"
      (insert "export FOO=BAR"))

    (with-temp-buffer
      (ben-mode 1)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (not (local-variable-p 'process-environment)))
      (ben-allow)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (local-variable-p 'process-environment))
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal "BAR" (getenv "FOO")))
      (when ben-async-processing
        (sleep-for 0.1))
      (should (eq ben--status 'on)))))

(ert-deftest ben-setting-removed-when-denied ()
  (ben-tests--with-temp-directory _
    (with-temp-file ".envrc"
      (insert "export FOO=BAR"))
    (ben-tests--exec "allow")

    (with-temp-buffer
      (ben-mode 1)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (local-variable-p 'process-environment))
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal "BAR" (getenv "FOO")))
      (when ben-async-processing
        (sleep-for 0.1))
      (should (eq ben--status 'on))
      (ben-deny)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (not (local-variable-p 'process-environment)))
      (when ben-async-processing
        (sleep-for 0.1))
      (should (eq ben--status 'denied)))))

(ert-deftest ben-reload-existing-buffer ()
  (ben-tests--with-temp-directory _
    (with-temp-file ".envrc"
      (insert "export FOO=BAR"))

    (ben-tests--exec "allow")

    (with-temp-buffer
      (ben-mode 1)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal "BAR" (getenv "FOO")))
      (with-temp-file ".envrc"
        (insert "export FOO=BAZ"))
      (ben-tests--exec "allow")
      (ben-reload)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal "BAZ" (getenv "FOO"))))))

(ert-deftest ben-masks-global-var-when-overridden ()
  (ben-tests--with-extra-global-env-var "FOO" "BANANA"
    (ben-tests--with-temp-directory _
      (with-temp-file ".envrc"
        (insert "export FOO=BAR"))

      (ben-tests--exec "allow")

      (with-temp-buffer
        (when ben-async-processing
          (sleep-for 0.1))
        (should (equal "BANANA" (getenv "FOO")))
        (ben-mode 1)
        (when ben-async-processing
          (sleep-for 0.1))
        (should (equal "BAR" (getenv "FOO")))))))

(ert-deftest ben-state-shared-between-buffers-in-dir ()
  (ben-tests--with-temp-directory _
    (with-temp-file ".envrc"
      (insert "export FOO=BAR"))

    (ben-tests--exec "allow")

    (with-temp-buffer
      (ben-mode 1)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (local-variable-p 'process-environment))
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal "BAR" (getenv "FOO")))

      (ben-tests--exec "deny")

      (with-temp-buffer
        (ben-mode 1)
        (when ben-async-processing
          (sleep-for 0.1))
        (should (local-variable-p 'process-environment))
        (when ben-async-processing
          (sleep-for 0.1))
        (should (equal "BAR" (getenv "FOO")))
        (ben-reload)
        (when ben-async-processing
          (sleep-for 0.1))
        (should (eq ben--status 'denied)))

      (when ben-async-processing
        (sleep-for 0.1))
      (should (eq ben--status 'denied))
      (when ben-async-processing
        (sleep-for 0.1))
      (should (not (local-variable-p 'process-environment))))))

(ert-deftest ben-remove-variable ()
  (ben-tests--with-temp-directory _
    (with-temp-file ".envrc"
      (insert "export FOO=BAR"))

    (ben-tests--exec "allow")

    (with-temp-buffer
      (ben-mode 1)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal "BAR" (getenv "FOO")))
      (with-temp-file ".envrc"
        (insert ""))
      (ben-allow)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal nil (getenv "FOO"))))))

(ert-deftest ben-cache-is-refreshed-if-global-env-changes ()
  (ben-tests--with-temp-directory _
    (with-temp-file ".envrc"
      (insert "export FOO=BAR"))

    (ben-tests--exec "allow")

    (with-temp-buffer
      (ben-mode 1)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal "BAR" (getenv "FOO")))
      (ben-tests--with-extra-global-env-var (symbol-name (gensym)) "blah"
        (with-temp-file ".envrc"
          (insert "export FOO=BAZ"))
        (ben-tests--exec "allow")
        (with-temp-buffer
          ;; We expect a cache miss, and therefore a refresh
          (ben--debug "buffer is %S" (current-buffer))
          (ben-mode 1)
          (when ben-async-processing
            (sleep-for 0.1))
          (should (local-variable-p 'process-environment))
          (should (equal "BAZ" (getenv "FOO"))))

        ;; TODO?
        ;; (should (local-variable-p 'process-environment))
        ;; (should (equal "BAZ" (getenv "FOO")))
        ))))

;; ;; Now requires a per-user config setting for direnv,
;; ;; so tests will fail by default.
;; (ert-deftest ben-fall-back-to-env-files ()
;;   (ben-tests--with-temp-directory _
;;     (with-temp-file ".env"
;;       (insert "FOO=BAR"))

;;     (ben-tests--exec "allow")

;;     (with-temp-buffer
;;       (ben-mode 1)
;;       (should (equal "BAR" (getenv "FOO"))))))
(require 'em-dirs)
(require 'eshell)

(ert-deftest ben-eshell-updates-environment-when-changing-directory ()
  (let ((current-dir default-directory))
    (eshell)
    (ben-tests--with-temp-directory ben-dir
      (with-temp-file ".envrc"
        (insert "export FOO=BAR"))

      (ben-tests--exec "allow")

      ;; ben mode is not activated
      (eshell/cd ben-dir)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal nil (getenv "FOO")))

      ;; ben mode is activated with option set to not update env on directory change
      (eshell/cd current-dir)
      (let ((ben-update-on-eshell-directory-change nil))
        (ben-mode 1))
      (eshell/cd ben-dir)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal nil (getenv "FOO")))

      ;; ben mode is activated and updates environment with default options
      (eshell/cd current-dir)
      (ben-mode -1)
      (ben-mode 1)
      (eshell/cd ben-dir)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal "BAR" (getenv "FOO")))

      ;; environment is cleared when exiting directory
      (eshell/cd current-dir)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal nil (getenv "FOO")))

      ;; environment is cleared when ben-mode is disabled
      (eshell/cd ben-dir)
      (ben-mode -1)
      (when ben-async-processing
        (sleep-for 0.1))
      (should (equal nil (getenv "FOO"))))))

(ert-deftest ben-concurrent-spinner-does-not-freeze ()
  "Regression test for the spinner-freeze bug.

This test creates 4 directories with a `.envrc' file containing a `sleep
TIME' directive.  The test loads each of those 4 environment
concurrently and ensures that one environment finishing earlier than the
others does not tear down the shared spinner.  Once finished, the status
of all the buffers loading the environment must the set to 'on'."
  ;; Create test environment directories.
  (let ((sleep-times '(1 2 3 4))
        test-directories bufs)
    (dolist (time sleep-times)
      (let ((dir (make-temp-file "ben-spinner-" t)))
        (push dir test-directories)
        (let ((default-directory dir))
          (with-temp-file ".envrc"
            (insert (format "sleep %d" time)))
          (ben-tests--exec "allow"))))

    ;; Load environments.
    (dolist (dir test-directories)
      (let ((buf (generate-new-buffer (format "*ben-spinner-test-%s*" dir))))
        (push buf bufs)
        (with-current-buffer buf
          (setq default-directory dir)
          (ben-mode 1))))

    ;; Wait for async processes to register.
    (when ben-async-processing
      (sleep-for 0.1))

    ;; For as long as at least one environment is still loading, the shared
    ;; spinner timer must stay alive.
    (while (> (hash-table-count ben--processes) 0)
      (should (timerp ben--status-timer))
      (sleep-for 0.1))

    ;; Once every environment has finished, the timer must have been torn down.
    (should (null ben--status-timer))

    ;; Every buffer must have settled on "on"; none should be stuck showing the
    ;; loading spinner.
    (dolist (buf bufs)
      (with-current-buffer buf
        (should (eq ben--status 'on))))))

;; TODO:
;; - Setting exec-path and eshell-path-env


(provide 'ben-tests)
;;; ben-tests.el ends here
