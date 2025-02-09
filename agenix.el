;;; agenix.el --- Decrypt and encrypt agenix secrets  -*- lexical-binding: t -*-

;; Copyright (C) 2022-2023 Tomasz Maciosowski (t4ccer)

;; Author: Tomasz Maciosowski <t4ccer@gmail.com>
;; Maintainer: Tomasz Maciosowski <t4ccer@gmail.com>
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/t4ccer/agenix.el
;; Version: 1.0

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Fully transparent editing of agenix secrets. Open a file, edit it, save it and it will be
;; encrypted automatically.

;;; Code:

(defcustom agenix-age-program "age"
  "The age program."
  :group 'agenix
  :type 'string)

(defcustom agenix-key-files '("~/.ssh/id_ed25519" "~/.ssh/id_rsa")
  "List of age key files."
  :group 'agenix
  :type '(repeat (choice (string :tag "Pathname to a key file")
                         (function :tag "Function returning the pathname to a key file"))))

(defcustom agenix-pre-mode-hook nil
  "Hook to run before entering `agenix-mode'.
Can be used to set up age binary path."
  :group 'agenix
  :type 'hook)

(defvar-local agenix--encrypted-fp nil)

(defvar-local agenix--keys nil)

(defvar-local agenix--undo-list nil)

(defvar-local agenix--point nil)

(define-derived-mode agenix-mode text-mode "agenix"
  "Major mode for agenix files.
Don't use directly, use `agenix-mode-if-with-secrets-nix' to ensure that
secrets.nix exists."
  (read-only-mode 1)

  (run-hooks 'agenix-pre-mode-hook)

  (agenix-decrypt-buffer)
  (goto-char (point-min))
  (setq buffer-undo-list nil)

  (setq require-final-newline nil)
  (setq buffer-auto-save-file-name nil)
  (setq write-contents-functions '(agenix-save-decrypted))

  ;; Reverting loads encrypted file back to the buffer, so we need to decrypt it
  (add-hook 'after-revert-hook
            (lambda () (when (eq major-mode 'agenix-mode) (agenix-decrypt-buffer)))))

(defun agenix--buffer-string* (buffer)
  "Like `buffer-string' but read from BUFFER parameter."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun agenix--with-temp-buffer (func)
  "Like `with-temp-buffer' but doesn't actually switch the buffer.
FUNC takes a temporary buffer that will be disposed after the call."
  (let* ((age-buf (generate-new-buffer "*age-buf*"))
         (res (funcall func age-buf)))
    (kill-buffer age-buf)
    res))

(defun agenix--identity-protected-p (identity-path)
  "Check if the identity file at IDENTITY-PATH is password protected.
Returns t if the file is protected, nil if it's unprotected.
See also https://security.stackexchange.com/a/245767/318401."
  (/= 0 (call-process "ssh-keygen" nil nil nil
                      "-y" "-P" "" "-f" identity-path)))

(defun agenix--prompt-password (identity-file)
  "Prompt for the password of IDENTITY-FILE."
  (read-passwd (format "Password for %s: " identity-file)))

(defun agenix--create-temp-identity (identity-path password)
  "Create a temporary copy of IDENTITY-PATH and remove its password protection.
PASSWORD is the current password of the identity file.
See also https://stackoverflow.com/a/112409/5616591.''"
  (let* ((temp-file (make-temp-file "agenix-temp-identity"))
         (copy-exit-code (call-process "cp" nil nil nil identity-path temp-file)))
    (if (= 0 copy-exit-code)
        (let ((rekey-exit-code (call-process "ssh-keygen" nil nil nil
                                             "-p" "-P" password "-N" "" "-f" temp-file)))
          (if (= 0 rekey-exit-code)
              temp-file
            (error "Failed to open private key %s. Wrong password? \
Please close the buffer and try again" identity-path)))
      (error "Failed to create temporary copy of identity file. \
Please close the buffer and try again"))))

(defun agenix--process-exit-code-and-output (program &rest args)
  "Run PROGRAM with ARGS and return the exit code and output in a list."
  (agenix--with-temp-buffer
   (lambda (buf) (list (apply #'call-process program nil buf nil args)
                       (agenix--buffer-string* buf)))))

(defun agenix--process-agenix-key-files ()
  "Read AGENIX-KEY-FILES, resolve any functions, and assert that paths exist."
  (let* (;; resolve functions
         (resolved-key-files
          (seq-map (lambda (el) (cond ((stringp el) (expand-file-name el))
                                      ((functionp el) (expand-file-name (funcall el)))
                                      (t ""))) agenix-key-files))
         ;; filter for files that actually exist
         (filtered-key-files
          (seq-filter (lambda (identity)
                        (and identity (file-exists-p (expand-file-name identity))))
                      resolved-key-files)))
    filtered-key-files))




(defun agenix--decrypt-current-buffer-using-cleartext-identities (cleartext-key-paths)
  "Decrypt current buffer in place using CLEARTEXT-KEY-PATHS.
Called as part of AGENIX-DECRYPT-BUFFER. Expects CLEARTEXT-KEYS to be a list of
private key paths to keys which exist and are not password protected."
  (let* ((age-flags (append (list "--decrypt")
                            (mapcan (lambda (path) (list "--identity" (expand-file-name path)))
                                    cleartext-key-paths)
                            (list (buffer-file-name))))
         (age-res (apply #'agenix--process-exit-code-and-output agenix-age-program age-flags))
         (age-exit-code (car age-res))
         (age-output (car (cdr age-res))))

    (if (= 0 age-exit-code)
        (progn
          ;; Replace buffer with decrypted content
          (read-only-mode -1)
          (erase-buffer)
          (insert age-output)

          ;; Mark buffer as not modified
          (set-buffer-modified-p nil)
          (setq buffer-undo-list agenix--undo-list))
      (error "Decryption failed: %s. Please close the buffer and try again" age-output))))

;;;###autoload
(defun agenix-decrypt-buffer (&optional encrypted-buffer)
  "Decrypt ENCRYPTED-BUFFER in place.
If ENCRYPTED-BUFFER is unset or nil, decrypt the current buffer. If all
AGENIX-KEY-FILES are cleartext (not password protected), pass them to age
command as identities. Else, prompt for which key to use, and then optionally
prompt for password."
  (interactive
   (when current-prefix-arg
     (list (read-buffer "Encrypted buffer: " (current-buffer) t))))

  (with-current-buffer (or encrypted-buffer (current-buffer))
    (let* ((nix-res (apply #'agenix--process-exit-code-and-output "nix-instantiate"
                           (list "--strict" "--json" "--eval" "--expr"
                                 (format
                                  "(import \"%s\").\"%s\".publicKeys"
                                  (agenix-locate-secrets-nix buffer-file-name)
                                  (agenix-path-relative-to-secrets-nix (buffer-file-name))))))
           (nix-exit-code (car nix-res))
           (nix-output (car (cdr nix-res))))

      (if (/= nix-exit-code 0)
          (warn "Nix evaluation error.
Probably file %s is not declared as a secret in 'secrets.nix' file.
Error: %s" (buffer-file-name) nix-output)
        (let* ((keys (json-parse-string nix-output :array-type 'list)))
          (setq agenix--encrypted-fp (buffer-file-name))
          (setq agenix--keys keys))

        ;; Check if file already exists
        (if (not (file-exists-p (buffer-file-name)))
            (progn
              (message "Not decrypting. File %s does not exist and will be created when you \
will save this buffer." (buffer-file-name))
              (read-only-mode -1))
          (let* (;; Make sure AGENIX-KEY-FILES exist and are strings
                 (processed-agenix-key-files (agenix--process-agenix-key-files)))
            ;; if no key files in `agenix-key-files` are password protected, proceed with decryption
            (if (seq-every-p (lambda (x) (not (agenix--identity-protected-p x)))
                             processed-agenix-key-files)
                (agenix--decrypt-current-buffer-using-cleartext-identities
                 processed-agenix-key-files)
              ;; else, pick one key file and possibly decrypt it. specifically, if the chosen key
              ;; is not cleartext, copy it to temp file and deobfuscate the temp file in place by
              ;; prompting for password. make sure to always delete that temp file again.
              (let* ((temp-identity-path nil)
                     (selected-identity-path
                      (expand-file-name
                       (completing-read "Select private key to use (or enter a custom path): "
                                        processed-agenix-key-files nil nil))))
                ;; always clean up temporary identity file, which may contain plaintext secret.
                (unwind-protect
                    (progn
                      (if (agenix--identity-protected-p selected-identity-path)
                          (let ((password (agenix--prompt-password selected-identity-path)))
                            (setq temp-identity-path
                                  (agenix--create-temp-identity selected-identity-path password)))
                        (setq temp-identity-path selected-identity-path))
                      (agenix--decrypt-current-buffer-using-cleartext-identities
                       (list temp-identity-path)))
                  (when (and temp-identity-path
                             (not (equal temp-identity-path selected-identity-path)))
                    (delete-file temp-identity-path)))))))))))

;;;###autoload
(defun agenix-save-decrypted (&optional unencrypted-buffer)
  "Encrypt UNENCRYPTED-BUFFER back to the original .age file.
If UNENCRYPTED-BUFFER is unset or nil, use the current buffer."
  (interactive
   (when current-prefix-arg
     (list (read-buffer "Unencrypted buffer: " (current-buffer) t))))
  (with-current-buffer (or unencrypted-buffer (current-buffer))
    (let* ((age-flags (list "--encrypt")))
      (progn
        (dolist (k agenix--keys)
          (setq age-flags (nconc age-flags (list "--recipient" k))))
        (setq age-flags (nconc age-flags (list "-o" agenix--encrypted-fp)))
        (let* ((decrypted-text (buffer-string))
               (age-res
                (agenix--with-temp-buffer
                 (lambda (buf)
                   (list
                    (apply #'call-process-region
                           decrypted-text nil
                           agenix-age-program
                           nil
                           buf
                           t
                           age-flags)
                    (agenix--buffer-string* buf))))))
          (when (/= 0 (car age-res))
            (error (car (cdr age-res))))
          (setq agenix--point (point))
          (setq agenix--undo-list buffer-undo-list)
          (revert-buffer :ignore-auto :noconfirm :preserve-modes)
          (set-buffer-modified-p nil)
          t)))))

(defun agenix-secrets-base-dir (pathname)
  "Return the directory above PATHNAME containing secrets.nix file, if one exists."
  (locate-dominating-file pathname "secrets.nix"))

(defun agenix-locate-secrets-nix (pathname)
  "Return the absolute path to secrets.nix in any directory containing PATHNAME."
  (when-let (dir (agenix-secrets-base-dir pathname))
    (expand-file-name "secrets.nix" dir)))

(defun agenix-path-relative-to-secrets-nix (pathname)
  "Convert absolute PATHNAME to a name relative to its secrets.nix."
  (when-let (dir (agenix-secrets-base-dir pathname))
    (file-relative-name pathname dir)))

;;;###autoload
(defun agenix-mode-if-with-secrets-nix ()
  "Enable `agenix-mode' if the current buffer is in a directory with secrets.nix."
  (interactive)
  (when (agenix-locate-secrets-nix buffer-file-name)
    (agenix-mode)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.age\\'" . agenix-mode-if-with-secrets-nix))

(provide 'agenix)
;;; agenix.el ends here
