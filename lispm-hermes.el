;;; lispm-hermes.el --- Hermes, one of the editor's agents  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-hermes
;; Version: 0.3.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, processes
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

;; Hermes, Nous Research's agent, as one of the editor's agents of LispM
;; Agent (lispm-agents.el), beside Claude Code and Codex: a package of its
;; own, which LispM Desktop's App Store installs.  Loading this file makes
;; Hermes an agent (`lispm-agents-define'); unloading it, as the App Store
;; does when it removes it, takes it away again.  It takes part while
;; `hermes' is on PATH: h in `lispm-agents-map' starts it in the current
;; project, and its sessions join the others.
;;
;; - Its sessions are read from Hermes's SQLite store, ~/.hermes/state.db,
;;   in one query, again only when the store or its write-ahead log
;;   changed.  The store is Hermes's own: renaming, deleting and exporting
;;   a session go through the `hermes' command.
;; - It sees Emacs's state through an MCP server per terminal
;;   (lispm-agents-mcp.el).  Hermes takes MCP servers from its
;;   config file alone, so this package's stdio bridge, bin/emacs-mcp, is
;;   named there once, as the server `emacs' (`lispm-hermes-setup'); each
;;   terminal then hands the bridge its server's address and a token file:
;;
;;     hermes, with LISPM_HERMES_MCP_URL and LISPM_HERMES_MCP_TOKEN_FILE set
;;       --> bin/emacs-mcp --> POST /mcp with "Authorization: Bearer TOKEN"
;;
;;   Hermes passes its environment on to the commands it runs, so the
;;   token is written to a file readable by its owner only, and only the
;;   file's name travels in the environment.
;; - It waits for its user's next message when its session's last message,
;;   in the store, is its answer: other agents' messages then reach it
;;   (`lispm-hermes--ready-p').

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'lispm-agents)
(require 'lispm-agents-mcp)


(defconst lispm-hermes-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "The directory of this package, holding its bridge and its icon.")

(defconst lispm-hermes-program "hermes"
  "Hermes's command.")

(defconst lispm-hermes-state-file (expand-file-name "~/.hermes/state.db")
  "SQLite store where Hermes keeps every session and its messages.")

(defconst lispm-hermes-config-file (expand-file-name "~/.hermes/config.yaml")
  "Hermes's configuration file, the only place it takes MCP servers from.")

(defconst lispm-hermes-bridge (expand-file-name "bin/emacs-mcp" lispm-hermes-directory)
  "The stdio MCP server Hermes runs, which forwards to a terminal's server.")

(defconst lispm-hermes-token-directory
  (expand-file-name "lispm-hermes/" temporary-file-directory)
  "Directory of the token files written for Hermes terminals.
It lies under the user's own temporary directory, which others cannot
enter.")

(defconst lispm-hermes-sources '("cli" "desktop")
  "Sources of the Hermes sessions listed: those a person began at a
terminal or in the desktop app, not those of messaging gateways or of
other programs driving Hermes.")

(defconst lispm-hermes-query
  "SELECT s.id, s.cwd, s.git_repo_root, s.title, s.started_at,
          (SELECT MAX(m.timestamp) FROM messages m WHERE m.session_id = s.id),
          (SELECT m.content FROM messages m
            WHERE m.session_id = s.id AND m.role = 'user' AND m.active = 1
            ORDER BY m.timestamp, m.id LIMIT 1)
     FROM sessions s
    WHERE s.hidden = 0 AND s.archived = 0 AND s.source IN (%s)
      AND NOT EXISTS (SELECT 1 FROM sessions c WHERE c.parent_session_id = s.id)"
  "Query listing Hermes sessions: id, directory, repository root, title,
start time, last message time and first prompt.  Sessions Hermes hides or
archives are left out, as is one that another session carries on after
compressing it.  %s takes a placeholder per listed source.")

;;;; Sessions (pure)

(defun lispm-hermes--prompt (content)
  "Return the prompt a person typed in Hermes message CONTENT, or nil.
CONTENT is text, or a JSON array of typed parts when it carried images."
  (let ((text (if (and (stringp content) (string-prefix-p "[" content))
                  (lispm-agents-content-text
                   (ignore-errors
                     (json-parse-string content :object-type 'plist :array-type 'list
                                        :null-object nil :false-object nil)))
                content)))
    (and (lispm-agents-human-text-p text) text)))

(defun lispm-hermes--session (row)
  "Return the Hermes session of ROW, a row of `lispm-hermes-query'.
Its title is the one Hermes gave or was given, else the first prompt; its
directory is the recorded one, else the repository, else home, which makes
it a chat.  Its :started time ties a freshly started terminal to it, see
`lispm-agents-claim-sessions'.  Return nil for a session with no
title and no prompt."
  (pcase-let ((`(,id ,cwd ,root ,title ,started ,last ,content) row))
    (when-let* ((title (or (and (stringp title) (not (string-blank-p title)) title)
                           (lispm-hermes--prompt content))))
      (list :agent 'hermes
            :id id
            :cwd (or (and cwd (not (string-empty-p cwd)) cwd)
                     (and root (not (string-empty-p root)) root)
                     (expand-file-name "~"))
            :title title
            :time (or last started)
            :started started))))

(defun lispm-hermes--short-id (id)
  "Return the end of ID that tells its session from others: Hermes ids
begin with the start time and end in random characters."
  (car (last (split-string id "_"))))

;;;; Sessions (effects)

(defvar lispm-hermes--cache nil
  "Memoized Hermes sessions as (STAMP . SESSIONS).
STAMP is the modification times of the store and its write-ahead log,
which Hermes updates in place.")

(defun lispm-hermes--rows ()
  "Return the rows of `lispm-hermes-query' from Hermes's store.
Return nil without the store, or without SQLite in this Emacs."
  (when (and (sqlite-available-p) (file-readable-p lispm-hermes-state-file))
    (let ((db (sqlite-open lispm-hermes-state-file)))
      (unwind-protect
          (sqlite-select db
                         (format lispm-hermes-query
                                 (mapconcat (lambda (_) "?") lispm-hermes-sources ", "))
                         lispm-hermes-sources)
        (sqlite-close db)))))

(defun lispm-hermes--stamp ()
  "Return the modification times of Hermes's store and its write-ahead log."
  (mapcar (lambda (file) (and (file-exists-p file) (lispm-agents-file-time file)))
          (list lispm-hermes-state-file (concat lispm-hermes-state-file "-wal"))))

(defun lispm-hermes-sessions ()
  "Return every recorded Hermes session, rereading the store when it changed.
A store that cannot be read lists no sessions, and says so."
  (let ((stamp (lispm-hermes--stamp)))
    (unless (and lispm-hermes--cache (equal (car lispm-hermes--cache) stamp))
      (setq lispm-hermes--cache
            (cons stamp
                  (condition-case err
                      (delq nil (mapcar #'lispm-hermes--session (lispm-hermes--rows)))
                    (error (message "Hermes sessions unavailable: %s" (error-message-string err))
                           nil)))))
    (cdr lispm-hermes--cache)))

(defun lispm-hermes--run (&rest args)
  "Run Hermes with ARGS and return its output.
Hermes's store is its own to change, so renaming, deleting and exporting
go through Hermes, and the memoized sessions are dropped.  Signal a user
error with Hermes's output when it fails."
  (with-temp-buffer
    (let ((status (apply #'call-process lispm-hermes-program nil t nil args)))
      (setq lispm-hermes--cache nil)
      (unless (eq status 0)
        (user-error "hermes %s: %s" (string-join args " ") (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun lispm-hermes--rename (session title)
  "Rename Hermes SESSION to TITLE in its store, where titles are unique, so
a title already in use is refused."
  (lispm-hermes--run "sessions" "rename" (plist-get session :id) title))

(defun lispm-hermes--delete (session)
  "Delete Hermes SESSION from its store."
  (lispm-hermes--run "sessions" "delete" "--yes" (plist-get session :id)))

(defun lispm-hermes--transcript (session)
  "Return a file holding Hermes SESSION's transcript: exported from the
store to Markdown in a fresh temporary directory."
  (let ((directory (make-temp-file "hermes-session-" t)))
    (lispm-hermes--run "sessions" "export" "--format" "md" "--yes"
                       "--session-id" (plist-get session :id) directory)
    (or (car (directory-files directory t "\\.md\\'"))
        (user-error "Hermes exported nothing for session %s" (plist-get session :id)))))

;;;; Waiting for its user

(defconst lispm-hermes-last-message-query
  "WITH RECURSIVE line(id) AS
     (SELECT ? UNION SELECT s.id FROM sessions s JOIN line ON s.parent_session_id = line.id)
   SELECT m.role, m.finish_reason, m.tool_calls IS NOT NULL FROM messages m
    WHERE m.session_id IN (SELECT id FROM line) AND m.active = 1
      AND m.role IN ('user', 'assistant', 'tool')
    ORDER BY m.timestamp DESC, m.id DESC LIMIT 1"
  "Query of the last message of a session, carried on after compressions:
its role, why it finished, and whether it calls tools.")

(declare-function lispm-agents-terminal-session-id "lispm-agents" (terminal))

(defun lispm-hermes--ready-p (terminal)
  "Return non-nil when the Hermes of TERMINAL waits for its user's next
message: the last message of its session is its answer, calling no tools.
Hermes records the session once its first message is sent."
  (when-let* (((fboundp 'lispm-agents-terminal-session-id))
              (id (lispm-agents-terminal-session-id terminal))
              ((sqlite-available-p))
              ((file-readable-p lispm-hermes-state-file)))
    (let ((db (sqlite-open lispm-hermes-state-file)))
      (unwind-protect
          (pcase (car (sqlite-select db lispm-hermes-last-message-query (list id)))
            (`("assistant" ,(or "stop" "length") 0) t))
        (sqlite-close db)))))

;;;; Emacs's state, over MCP

(cl-defstruct (lispm-hermes-mcp (:include lispm-agents-mcp)
                                (:constructor lispm-hermes-mcp--make))
  "The MCP server of a Hermes terminal.")

(defun lispm-hermes--token-file (server)
  "Return the file holding SERVER's token for the bridge."
  (expand-file-name (format "%d.token" (lispm-agents-mcp-port server))
                    lispm-hermes-token-directory))

(defun lispm-hermes--write-token-file (server)
  "Write SERVER's token to a file only its owner can read.
A stale file from a crash is replaced rather than reused with whatever
permissions it had."
  (let ((file (lispm-hermes--token-file server)))
    (with-file-modes #o700
      (make-directory lispm-hermes-token-directory t))
    (ignore-errors (delete-file file))
    (with-file-modes #o600
      (write-region (lispm-agents-mcp-token server) nil file nil 'silent))))

(cl-defmethod lispm-agents-context-environment ((server lispm-hermes-mcp))
  "Point the bridge Hermes runs at SERVER and its token file.
The bridge reaches loopback without a proxy on its own."
  (list (format "LISPM_HERMES_MCP_URL=http://127.0.0.1:%d/mcp" (lispm-agents-mcp-port server))
        (format "LISPM_HERMES_MCP_TOKEN_FILE=%s" (lispm-hermes--token-file server))))

(cl-defmethod lispm-agents-context-stop ((server lispm-hermes-mcp))
  "Stop SERVER and remove its token file."
  (cl-call-next-method)
  (ignore-errors (delete-file (lispm-hermes--token-file server))))

(defun lispm-hermes-configured ()
  "Return how Hermes's config names the MCP server `emacs': `this' when it
runs this package's bridge, `other' when it runs something else, as the
bridge of an earlier install, and nil when there is none.  The entry is
Hermes's to write, see `lispm-hermes-setup'."
  (when (file-readable-p lispm-hermes-config-file)
    (with-temp-buffer
      (insert-file-contents lispm-hermes-config-file)
      (goto-char (point-min))
      (when (re-search-forward "^mcp_servers:" nil t)
        (let ((end (save-excursion
                     (if (re-search-forward "^[^ \t\n#]" nil t) (match-beginning 0) (point-max)))))
          (when (re-search-forward "^\\([ \t]+\\)emacs:" end t)
            (let* ((indent (length (match-string 1)))
                   (entry-end (save-excursion
                                (forward-line 1)
                                (while (and (< (point) end)
                                            (or (looking-at-p "[ \t]*$")
                                                (> (current-indentation) indent)))
                                  (forward-line 1))
                                (point))))
              (if (search-forward lispm-hermes-bridge entry-end t) 'this 'other))))))))

(defun lispm-hermes--context (directory)
  "Serve Emacs's state to a Hermes terminal running in DIRECTORY.
Hermes sees it only once its config names the bridge, which is said when
it does not."
  (let ((server (lispm-agents-mcp-start "hermes-mcp" #'lispm-hermes-mcp--make directory)))
    (lispm-hermes--write-token-file server)
    (pcase (lispm-hermes-configured)
      ('this)
      ('other (message "Hermes runs another bridge as its MCP server `emacs': %s"
                       "remove it with `hermes mcp remove emacs', then M-x lispm-hermes-setup"))
      (_ (message "Hermes cannot see Emacs's state until M-x lispm-hermes-setup runs once")))
    server))

(defun lispm-hermes-setup-arguments ()
  "Return the arguments that have Hermes add the bridge as its server `emacs'.
The environment entries are placeholders Hermes fills from its environment
at each start, so one entry serves every terminal."
  (list "mcp" "add" "emacs"
        "--command" lispm-hermes-bridge
        "--env" "LISPM_HERMES_MCP_URL=${LISPM_HERMES_MCP_URL}"
        "LISPM_HERMES_MCP_TOKEN_FILE=${LISPM_HERMES_MCP_TOKEN_FILE}"))

(defun lispm-hermes-setup ()
  "Have Hermes add Emacs as an MCP server, in a terminal, once.
Hermes takes MCP servers from its config file alone and adds one only
interactively: the terminal runs its add command, which tries the bridge,
finds it serving no tools outside an agent terminal, and asks whether to
save the server anyway.  Answer yes.  Every Hermes terminal started from
Emacs then sees Emacs's state."
  (interactive)
  (unless (executable-find lispm-hermes-program)
    (user-error "Hermes is not installed: `%s' is not on PATH" lispm-hermes-program))
  (pop-to-buffer
   (let ((process-environment (lispm-agents-independent-environment process-environment)))
     (apply #'lispm-agents-terminal-make "hermes setup" lispm-hermes-program
            (lispm-hermes-setup-arguments)))))

;;;; The agent

(defun lispm-hermes-new ()
  "Start a new Hermes session at the current project root."
  (interactive)
  (lispm-agents-new 'hermes))

(lispm-agents-define
 'hermes
 :name "Hermes"
 ;; The Hermes desktop app's icon, the girl with the N choker.
 :icon `(lispm-agents-image-icon ,(expand-file-name "icons/hermes.png" lispm-hermes-directory) nil)
 :command #'lispm-hermes-new
 :key "h"
 :program lispm-hermes-program
 :sessions #'lispm-hermes-sessions
 :rename #'lispm-hermes--rename
 :delete #'lispm-hermes--delete
 :transcript #'lispm-hermes--transcript
 :short-id #'lispm-hermes--short-id
 :new-arguments (lambda () (cons nil (list "chat")))
 :resume-arguments (lambda (id) (list "chat" "--resume" id))
 :context #'lispm-hermes--context
 :ready #'lispm-hermes--ready-p)

(defun lispm-hermes-unload-function ()
  "Take Hermes away from the editor's agents, as this package is unloaded."
  (lispm-agents-undefine 'hermes)
  ;; Unloading goes on as usual.
  nil)

(provide 'lispm-hermes)
;;; lispm-hermes.el ends here
