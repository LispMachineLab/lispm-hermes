;;; lispm-hermes-test.el --- Tests for lispm-hermes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-hermes
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Run with `make test', lispm-agent's lisp/ on the load path.  They need
;; neither Hermes nor its store: the store is made up when read.

;;; Code:

(require 'ert)
(require 'lispm-hermes)

(ert-deftest lispm-hermes-test-defined-on-load ()
  "Loaded, Hermes is one of the editor's agents, taking part while its
command is on PATH, started with h."
  (let ((props (alist-get 'hermes lispm-agents-defined)))
    (should (equal (plist-get props :name) "Hermes"))
    (should (equal (plist-get props :program) "hermes"))
    (should (equal (plist-get props :key) "h"))
    (should-not (plist-get props :built-in))
    (should (file-readable-p (nth 1 (plist-get props :icon)))))
  (cl-letf (((symbol-function 'executable-find) #'ignore))
    (should-not (lispm-agents-available-p 'hermes)))
  (cl-letf (((symbol-function 'executable-find) (lambda (program &rest _) (concat "/bin/" program))))
    (should (lispm-agents-available-p 'hermes))
    (should (eq (keymap-lookup lispm-agents-map "h") 'lispm-hermes-new))))

(ert-deftest lispm-hermes-test-sessions-from-rows ()
  "A row of the store is a session titled by Hermes, else by its first
prompt, which may come as typed parts; one with neither is left out; a
session without a directory is a chat at home."
  (should (equal (lispm-hermes--session '("20261020_0800_ab12" "/src/x" nil "Fix it" 10.0 20.0 "hi"))
                 '(:agent hermes :id "20261020_0800_ab12" :cwd "/src/x" :title "Fix it"
                   :time 20.0 :started 10.0)))
  (should (equal (plist-get (lispm-hermes--session
                             '("i" "" "/src/y" "" 10.0 nil "[{\"type\":\"text\",\"text\":\"Look\"}]"))
                            :title)
                 "Look"))
  (should (equal (plist-get (lispm-hermes--session '("i" "" "/src/y" nil 10.0 nil "Go")) :cwd) "/src/y"))
  (should (equal (plist-get (lispm-hermes--session '("i" nil nil nil 10.0 nil "Go")) :cwd)
                 (expand-file-name "~")))
  (should-not (lispm-hermes--session '("i" "/src" nil nil 10.0 nil "<context>")))
  (should (equal (lispm-hermes--short-id "20261020_080000_ab12cd") "ab12cd")))

(ert-deftest lispm-hermes-test-ready-when-it-answered ()
  "Hermes waits for its user once its session's last message is its answer;
not while it calls tools or a tool answers, nor before its session is
recorded.  A session carried on after compression is followed."
  (skip-unless (and (sqlite-available-p) (fboundp 'lispm-agents-terminal-session-id)))
  (let* ((lispm-hermes-state-file (make-temp-file "lispm-hermes-test" nil ".db"))
         (terminal (generate-new-buffer " *hermes:lispm-hermes-test*"))
         (db (sqlite-open lispm-hermes-state-file))
         (message (lambda (session role &optional finish calls)
                    (sqlite-execute db "INSERT INTO messages (session_id, role, finish_reason, tool_calls, timestamp, active)
                                        VALUES (?, ?, ?, ?, (SELECT count(*) FROM messages), 1)"
                                    (list session role finish calls)))))
    (unwind-protect
        (progn
          (sqlite-execute db "CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT)")
          (sqlite-execute db "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT,
                              role TEXT, finish_reason TEXT, tool_calls TEXT, timestamp REAL, active INTEGER)")
          (sqlite-execute db "INSERT INTO sessions VALUES ('a', NULL), ('b', 'a')")
          (cl-letf (((symbol-function 'lispm-agents-sessions-list) #'ignore))
            (should-not (lispm-hermes--ready-p terminal))
            (with-current-buffer terminal (setq lispm-agents-buffer-session-id "a"))
            (funcall message "a" "user")
            (should-not (lispm-hermes--ready-p terminal))
            (funcall message "a" "assistant" "tool_calls" "[{}]")
            (should-not (lispm-hermes--ready-p terminal))
            (funcall message "a" "tool")
            (should-not (lispm-hermes--ready-p terminal))
            (funcall message "a" "assistant" "stop")
            (should (lispm-hermes--ready-p terminal))
            ;; Compressed into b, the session goes on there.
            (funcall message "b" "user")
            (should-not (lispm-hermes--ready-p terminal))
            (funcall message "b" "assistant" "stop")
            (should (lispm-hermes--ready-p terminal))))
      (sqlite-close db)
      (kill-buffer terminal)
      (delete-file lispm-hermes-state-file))))

(ert-deftest lispm-hermes-test-sessions-reread-when-the-store-changes ()
  "The store is read again only when it or its write-ahead log changed."
  (let ((lispm-hermes--cache nil)
        (stamp '(1.0 nil))
        (reads 0))
    (cl-letf (((symbol-function 'lispm-hermes--stamp) (lambda () stamp))
              ((symbol-function 'lispm-hermes--rows)
               (lambda () (setq reads (1+ reads)) '(("i" "/src" nil "T" 1.0 2.0 nil)))))
      (should (equal (length (lispm-hermes-sessions)) 1))
      (lispm-hermes-sessions)
      (should (= reads 1))
      (setq stamp '(1.0 3.0))
      (lispm-hermes-sessions)
      (should (= reads 2)))))

(ert-deftest lispm-hermes-test-configured ()
  "Hermes's config names this package's bridge, another, or none."
  (let* ((directory (make-temp-file "lispm-hermes-test" t))
         (lispm-hermes-config-file (expand-file-name "config.yaml" directory)))
    (unwind-protect
        (cl-flet ((config (text) (with-temp-file lispm-hermes-config-file (insert text))))
          (should-not (lispm-hermes-configured))
          (config "model: x\nmcp_servers:\n  other:\n    command: /bin/true\n")
          (should-not (lispm-hermes-configured))
          (config (format "mcp_servers:\n  emacs:\n    command: %s\n    env:\n      A: b\nmodel: x\n"
                          lispm-hermes-bridge))
          (should (eq (lispm-hermes-configured) 'this))
          (config "mcp_servers:\n  emacs:\n    command: /old/bin/emacs-mcp\n  other:\n    command: x\n")
          (should (eq (lispm-hermes-configured) 'other))
          (config (format "mcp_servers:\n  emacs:\n    command: /old/bin/emacs-mcp\n  other:\n    command: %s\n"
                          lispm-hermes-bridge))
          (should (eq (lispm-hermes-configured) 'other)))
      (delete-directory directory t))))

(ert-deftest lispm-hermes-test-setup-names-the-bridge ()
  "Setup has Hermes run this package's bridge, an executable, with the
placeholders each terminal fills."
  (should (file-executable-p lispm-hermes-bridge))
  (let ((arguments (lispm-hermes-setup-arguments)))
    (should (equal (seq-take arguments 3) '("mcp" "add" "emacs")))
    (should (member lispm-hermes-bridge arguments))
    (should (member "LISPM_HERMES_MCP_URL=${LISPM_HERMES_MCP_URL}" arguments))))

(ert-deftest lispm-hermes-test-server-token-file ()
  "A Hermes terminal's server hands the bridge its address and a token
file only its owner can read, removed when the server stops."
  (let* ((lispm-hermes-token-directory (make-temp-file "lispm-hermes-test-tokens" t))
         (lispm-hermes-config-file "/nonexistent/config.yaml")
         (inhibit-message t)
         (server (lispm-hermes--context temporary-file-directory))
         (file (lispm-hermes--token-file server)))
    (unwind-protect
        (progn
          (should (lispm-hermes-mcp-p server))
          (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                         (lispm-agents-mcp-token server)))
          (should (= (file-modes file) #o600))
          (should (member (format "LISPM_HERMES_MCP_TOKEN_FILE=%s" file)
                          (lispm-agents-context-environment server)))
          (lispm-agents-context-stop server)
          (should-not (file-exists-p file)))
      (ignore-errors (lispm-agents-context-stop server))
      (delete-directory lispm-hermes-token-directory t))))

(ert-deftest lispm-hermes-test-unloading-takes-it-away ()
  "Unloading the package, as the App Store does removing it, takes Hermes
away from the agents and stops the servers of its running terminals,
their token files removed; loading it again brings it back."
  (let* ((lispm-hermes-token-directory (make-temp-file "lispm-hermes-test-tokens" t))
         (lispm-hermes-config-file "/nonexistent/config.yaml")
         (inhibit-message t)
         (terminal (get-buffer-create " *lispm-hermes-test terminal*"))
         (server (lispm-hermes--context temporary-file-directory))
         (file (lispm-hermes--token-file server)))
    (unwind-protect
        (progn
          (with-current-buffer terminal (setq lispm-agents-buffer-agent 'hermes))
          (lispm-agents-context-bind server terminal)
          (unload-feature 'lispm-hermes t)
          (should-not (assq 'hermes lispm-agents-defined))
          (should-not (process-live-p (lispm-agents-mcp-server server)))
          (should-not (file-exists-p file))
          (should (buffer-live-p terminal)))
      (require 'lispm-hermes)
      (kill-buffer terminal)
      (delete-directory lispm-hermes-token-directory t)))
  (should (assq 'hermes lispm-agents-defined)))

(ert-deftest lispm-hermes-test-knows-no-desktop ()
  "Hermes's extension stands alone beside lispm-agent: none of its files
but the tests names LispM Desktop's code."
  (dolist (file (directory-files (file-name-directory (locate-library "lispm-hermes")) t "\\.el\\'"))
    (with-temp-buffer
      (insert-file-contents file)
      (should-not (and (re-search-forward "lispm-desktop\\|platinum" nil t)
                       (format "%s:%d" (file-name-nondirectory file) (line-number-at-pos)))))))

(provide 'lispm-hermes-test)
;;; lispm-hermes-test.el ends here
