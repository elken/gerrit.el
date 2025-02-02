;;; gerrit-rest.el --- REST layer of gerrit.el -*- lexical-binding: t; -*-

;; Copyright (C) 2019 Thomas Hisch <t.hisch@gmail.com>
;;
;; Author: Thomas Hisch <t.hisch@gmail.com>
;; Version: 0.1
;; URL: https://github.com/thisch/gerrit.el
;; Package-Requires: ((emacs "25.1") (magit "2.13.1") (s "1.12.0"))

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;; 02110-1301, USA.

;;; Commentary:

;; helper functions using the REST API of gerrit

;;; Code:

(eval-when-compile (require 'subr-x)) ;; when-let
(require 'auth-source)
(require 's)
(require 'json)
(require 'cl-lib)
(require 'cl-extra) ;; for cl-prettyprint

(defvar gerrit-host)
(defvar gerrit-patch-buffer)
(defvar url-http-end-of-headers)

(defcustom gerrit-rest-endpoint-prefix "/a"
  "String that is appended to 'gerrit-host`.
For newer gerrit servers this needs to be set to /a, whereas on older
servers it needs to be set to an empty string."
  :group 'gerrit
  :type 'str)

(defun gerrit-rest-authentication ()
  "Return an encoded string with gerrit username and password."
  (let ((pass-entry (auth-source-user-and-password gerrit-host)))
    (when-let ((username (nth 0 pass-entry))
               (password (nth 1 pass-entry)))
      (base64-encode-string
       (concat username ":" password)))))

(defmacro gerrit-rest--read-json (str)
  "Read json string STR."
  (if (progn
        (require 'json)
        (fboundp 'json-parse-string))
      `(json-parse-string ,str
                          :object-type 'alist
                          :array-type 'list
                          :null-object nil
                          :false-object nil)
    `(let ((json-array-type 'list)
           (json-object-type 'alist)
           (json-false nil))
       (json-read-from-string ,str))))

(defun gerrit-rest-sync (method data &optional path)
  "Interact with the API using method METHOD and data DATA.
Optional arg PATH may be provided to specify another location further
down the URL structure to send the request."
  (let ((url-request-method method)
        (url-request-extra-headers
         `(("Content-Type" . "application/json")
           ("Authorization" . ,(concat "Basic " (gerrit-rest-authentication)))))
        (url-request-data data)
        (target (concat (gerrit--get-protocol) gerrit-host gerrit-rest-endpoint-prefix path)))

    (with-current-buffer (url-retrieve-synchronously target t)
      (gerrit-rest--read-json
       (progn
         (goto-char url-http-end-of-headers)
         ;; if there is an error in search-forward-regexp, write
         ;; the buffer contents to a *gerrit-rest-status* buffer
         (if-let ((pos (search-forward-regexp "^)]}'$" nil t)))
             (buffer-substring pos (point-max))
           ;; ")]}'" was not found in the REST response
           (let ((buffer (get-buffer-create "*gerrit-rest-status*"))
                 (contents (buffer-substring (point-min) (point-max))))
             (with-current-buffer buffer
               (goto-char (point-max))
               (insert ?\n)
               (insert (format "%s: %s (%s)" url-request-method target url-request-extra-headers))
               (insert ?\n)
               (insert contents)
               (error (concat "error with gerrit request (take a look at the "
                              "*gerrit-rest-status* buffer for more information"))))))))))

(defun gerrit-rest--escape-project (project)
  "Escape project name PROJECT for usage in REST API requets."
  (s-replace-all '(("/" . "%2F")) project))

(defun gerrit-rest-get-server-version ()
  "Return the gerrit server version."
  (interactive)
  (let ((versionstr (gerrit-rest-sync "GET" nil "/config/server/version")))
    (when (called-interactively-p 'interactive)
      (message versionstr))
    versionstr))

(defun gerrit-rest-get-server-info ()
  "Return the gerrit server info."
  (interactive)
  (let ((serverinfo (gerrit-rest-sync "GET" nil "/config/server/info")))
    (when (called-interactively-p 'interactive)
      (switch-to-buffer (get-buffer-create "*gerrit-server-info*"))
      (erase-buffer)
      (cl-prettyprint serverinfo)
      (unless buffer-read-only
        (read-only-mode t))
      (lisp-mode))
    serverinfo))

(defun gerrit-rest-get-change-info (changenr)
  "Return information about an open change with CHANGENR."
  (interactive "sEnter a changenr name: ")
  (let* ((req (concat "/changes/"
                      changenr
                      "?o=DOWNLOAD_COMMANDS&"
                      "o=CURRENT_REVISION&"
                      "o=CURRENT_COMMIT&"
                      "o=DETAILED_LABELS&"
                      "o=DETAILED_ACCOUNTS")))
         (gerrit-rest-sync "GET" nil req)))

(defun gerrit-rest-get-topic-info (topicname)
  "Return information about an open topic with TOPICNAME."
  ;; TODO create new buffer and insert stuff there
  ;; TODO query open topics
  (interactive "sEnter a topic name: ")
  (let* ((fmtstr (concat "/changes/?q=is:open+topic:%s&"
                         "o=DOWNLOAD_COMMANDS&"
                         "o=CURRENT_REVISION&"
                         "o=CURRENT_COMMIT&"
                         "o=DETAILED_LABELS&"
                         "o=DETAILED_ACCOUNTS"))
         (req (format fmtstr topicname)))
    (gerrit-rest-sync "GET" nil req)))

(defun gerrit-rest--get-gerrit-accounts ()
  "Return an alist of all active gerrit users."
  (interactive)
  (condition-case nil
      (mapcar (lambda (account-info) (cons (cdr (assoc '_account_id account-info))
                                      (cdr (assoc 'username account-info))))
              ;; see https://gerrit-review.googlesource.com/Documentation/rest-api-accounts.html
              ;; and https://gerrit-review.googlesource.com/Documentation/user-search-accounts.html#_search_operators
              (gerrit-rest-sync "GET" nil "/accounts/?q=is:active&o=DETAILS&S=0"))
    (error '())))

(defun gerrit-rest-open-reviews-for-project (project)
  "Return list of open reviews returned for the project PROJECT."
  (interactive "sEnter gerrit project: ")
  ;; see https://gerrit-review.googlesource.com/Documentation/rest-api-changes.html#list-changes
  (let* ((limit-entries 25)
         (req (format (concat "/changes/?q=is:open+project:%s&"
                              "o=CURRENT_REVISION&"
                              "o=CURRENT_COMMIT&"
                              "o=DETAILED_LABELS&"
                              (format "n=%d&" limit-entries)
                              "o=DETAILED_ACCOUNTS")
                      (funcall #'gerrit-rest--escape-project project)))
         (resp (gerrit-rest-sync "GET" nil req)))
    ;; (setq open-reviews-response resp) ;; for debugging only (use M-x ielm)
    resp))


;; change commands

(defun gerrit-rest-change-set-assignee (changenr assignee)
  "Set the assignee to ASSIGNEE of a change with nr CHANGENR."
  (interactive "sEnter a changenr: \nsEnter assignee: ")
  ;; TODO error handling?
  (gerrit-rest-sync "PUT"
                    (encode-coding-string (json-encode
                                           `((assignee . ,assignee))) 'utf-8)
                    (format "/changes/%s/assignee"  changenr)))

(defun gerrit-rest-change-add-reviewer (changenr reviewer)
  "Add REVIEWER to a change with nr CHANGENR."
  (interactive "sEnter a changenr: \nsEnter reviewer: ")
  ;; Do we want to verify the return entity?
  (gerrit-rest-sync "POST"
                    (encode-coding-string (json-encode
                                           `((reviewer . ,reviewer))) 'utf-8)
                    (format "/changes/%s/reviewers/%s"  changenr reviewer)))

(defun gerrit-rest-change-remove-reviewer (changenr reviewer)
  "Remove REVIEWER from a change with nr CHANGENR."
  (interactive "sEnter a changenr: \nsEnter reviewer: ")
  (gerrit-rest-sync "DELETE"
                    nil
                    (format "/changes/%s/reviewers/%s"  changenr reviewer)))

(defun gerrit-rest-change-set-topic (changenr topic)
  "Set the topic to TOPIC of a change CHANGENR."
  (interactive "sEnter a changenr: \nsEnter topic: ")
  (gerrit-rest-sync "PUT"
                    (encode-coding-string (json-encode
                                           `((topic . ,topic))) 'utf-8)
                    (format "/changes/%s/topic" changenr)))

(defun gerrit-rest-change-delete-topic (changenr)
  "Delete the topic of a change CHANGENR."
  (interactive "sEnter a changenr: ")
  (gerrit-rest-sync "DELETE"
                    nil
                    (format "/changes/%s/topic" changenr)))

(defun gerrit-rest-change-get-messages (changenr)
  ;; note that filenames are returned as symbols
  (gerrit-rest-sync "GET" nil (format "/changes/%s/messages" changenr)))

(defun gerrit-rest-change-get-comments (changenr)
  ;; note that filenames are returned as symbols
  (gerrit-rest-sync "GET" nil (format "/changes/%s/comments" changenr)))

(defun gerrit-rest-change-set-vote (changenr vote message)
  "Set a Code-Review vote VOTE of a change CHANGENR.
A comment MESSAGE can be provided."
  (interactive "sEnter a changenr: \nsEnter vote [-2, -1, 0, +1, +2]: \nsEnter message: ")
  (gerrit-rest-sync "POST"
                    (encode-coding-string (json-encode
                                           `((message . ,message)
                                             (labels .
                                               ((Code-Review . ,vote))))) 'utf-8)
                    (format "/changes/%s/revisions/current/review" changenr)))

(defun gerrit-rest-change-verify (changenr vote message)
  "Verify a change CHANGENR by voting with VOTE.
A comment MESSAGE can be provided."
  (interactive "sEnter a changenr: \nsEnter vote [-1, 0, +1]: \nsEnter message: ")
  (gerrit-rest-sync "POST"
                    (encode-coding-string (json-encode
                                           `((message . ,message)
                                             (labels .
                                               ((Verified . ,vote))))) 'utf-8)
                    (format "/changes/%s/revisions/current/review" changenr)))

(defun gerrit-rest-change-set-Work-in-Progress (changenr)
  "Set the state of the change CHANGENR to Work-in-Progress."
  (interactive "sEnter a changenr: ")
  (gerrit-rest-sync "POST"
                    (encode-coding-string (json-encode
                                           `((message . ,"Set using gerrit.el"))) 'utf-8)
                    (format "/changes/%s/wip" changenr)))

(defun gerrit-rest-change-set-Ready-for-Review (changenr)
  "Set the state of the change CHANGENR to Reday-for-Review."
  (interactive "sEnter a changenr: ")
  (gerrit-rest-sync "POST"
                    (encode-coding-string (json-encode
                                           `((message . ,"Set using gerrit.el"))) 'utf-8)
                    (format "/changes/%s/ready" changenr)))

(defun gerrit-rest-change-add-comment (changenr comment)
  "Add a comment message COMMENT to latest version of change CHANGENR."
  (interactive "sEnter changenr: \nsEnter comment: ")
  (gerrit-rest-sync "POST"
                    (encode-coding-string (json-encode
                                           `((message . ,comment))) 'utf-8)
                    (format "/changes/%s/revisions/current/review" changenr)))

(defun gerrit-rest-change-get-labels (changenr)
  "Return the current labels dictionary of a change CHANGENR."
  (interactive "sEnter changenr: ")
  (let* ((req (format "/changes/%s/revisions/current/review" changenr))
         (resp (gerrit-rest-sync "GET" nil req)))
    (assoc 'labels (cdr resp))))

(defun gerrit-rest-change-query (expression)
  "Return information about changes that match EXPRESSION."
  (interactive "sEnter a search expression: ")
  (gerrit-rest-sync "GET" nil
                    (concat (format "/changes/?q=%s&" expression)
                            "o=CURRENT_REVISION&"
                            "o=CURRENT_COMMIT&"
                            "o=LABELS"
                            ;; "o=DETAILED_LABELS"
                            ;; "o=DETAILED_ACCOUNTS"))
                            )))

(defun gerrit-rest-change-get (changenr)
  "Return information about change with CHANGENR."
  (interactive "sEnter changenr: ")
  (gerrit-rest-sync "GET" nil
                   (format "/changes/%s" changenr)))

(defun gerrit-rest-change-patch (changenr)
  "Download latest patch of change with CHANGENR and open it in new buffer.

This function can be called even if the project that corresponds
to CHANGENR is not locally cloned."
  (interactive "sEnter changenr: ")
  ;; does not return json
  (let ((url-request-method "GET")
        (url-request-extra-headers
         `(("Authorization" . ,(concat "Basic " (gerrit-rest-authentication)))))
        (url-request-data nil)
        (target (concat (gerrit--get-protocol) gerrit-host gerrit-rest-endpoint-prefix
                        (format "/changes/%s/revisions/current/patch" changenr))))
    (message "Opening patch of %s" changenr)
    (setq gerrit-patch-buffer (get-buffer-create "*gerrit-patch*"))

    (with-current-buffer gerrit-patch-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (url-insert-file-contents target)
        (base64-decode-region (point-min) (point-max))
        (delete-trailing-whitespace))
      (unless buffer-read-only
        (read-only-mode t))
      ;; using magit-diff-mode would be nice here, but it doesn't work.
      (unless (bound-and-true-p diff-mode)
        (diff-mode))
      ;; currently [TAB] is bound to diff-hunk-next. Do we want to change it
      ;; to `outline-cycle'?
      ;; beginning with emacs 28 set outline-minor-mode-cycle to t.
      (outline-minor-mode))

    (switch-to-buffer gerrit-patch-buffer)))


;;  topic commands

(defun gerrit-rest--change-info-to-unique-changeid (change-info)
  (concat (gerrit-rest--escape-project (alist-get 'project change-info))
          "~"
          (alist-get 'branch change-info)
          "~"
          (alist-get 'change_id change-info)))

(defun gerrit-rest-topic-set-assignee (topic assignee)
  "Set the ASSIGNEE of all changes of a TOPIC."
 (interactive "sEnter a topic: \nsEnter assignee: ")
 (cl-loop for change-info in (gerrit-rest-get-topic-info topic) do
          (let ((changenr (gerrit-rest--change-info-to-unique-changeid change-info)))
            (message "Setting assignee %s for %s" assignee changenr)
            (gerrit-rest-change-set-assignee changenr assignee))))

(defun gerrit-rest-topic-add-reviewer (topic reviewer)
  "Add a REVIEWER to all changes of a TOPIC."
 (interactive "sEnter a topic: \nsEnter reviewer: ")
 (cl-loop for change-info in (gerrit-rest-get-topic-info topic) do
          (let ((changenr (gerrit-rest--change-info-to-unique-changeid change-info)))
            (message "Adding reviewer %s to %s" reviewer changenr)
            (gerrit-rest-change-add-reviewer changenr reviewer))))

(defun gerrit-rest-topic-remove-reviewer (topic reviewer)
  "Remove a REVIEWER from all changes of a TOPIC."
 (interactive "sEnter a topic: \nsEnter reviewer: ")
 (cl-loop for change-info in (gerrit-rest-get-topic-info topic) do
          (let ((changenr (gerrit-rest--change-info-to-unique-changeid change-info)))
            (message "Removing reviewer %s from %s" reviewer changenr)
            (gerrit-rest-change-remove-reviewer changenr reviewer))))

(defun gerrit-rest-topic-set-vote (topic vote message)
  "Set a Code-Review vote VOTE for all changes of a topic TOPIC.
A comment MESSAGE can be provided."
 (interactive "sEnter a topic: \nsEnter vote [-2, -1, 0, +1, +2]: \nsEnter message: ")
 (cl-loop for change-info in (gerrit-rest-get-topic-info topic) do
          (let ((changenr (gerrit-rest--change-info-to-unique-changeid change-info)))
            (message "Setting vote %s for %s" vote changenr)
            (gerrit-rest-change-set-vote changenr vote message))))

(defun gerrit-rest-topic-verify (topic vote message)
  "Verify a topic TOPIC by voting with VOTE.
A comment MESSAGE can be provided."
 (interactive "sEnter a topic: \nsEnter vote [-1, 0, +1]: \nsEnter message: ")
 (cl-loop for change-info in (gerrit-rest-get-topic-info topic) do
          (let ((changenr (gerrit-rest--change-info-to-unique-changeid change-info)))
            (message "Setting Verify-vote %s for %s" vote changenr)
            (gerrit-rest-change-verify changenr vote message))))

(provide 'gerrit-rest)

;;; gerrit-rest.el ends here
