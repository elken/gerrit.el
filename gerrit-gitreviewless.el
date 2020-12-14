;;; gerrit-gitreviewless.el --- Upload/Download tools w/o git-review -*- lexical-binding: t; -*-

;; Copyright (C) 2020 Thomas Hisch <t.hisch@gmail.com>
;;
;; Author: Thomas Hisch <t.hisch@gmail.com>
;; Version: 0.1
;; URL: https://github.com/thisch/gerrit.el
;; Package-Requires: ((emacs "25.1") (hydra "0.15.0") (magit "2.13.1") (s "1.12.0"))

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
;;
;; TODO finalize API (think about a consistent naming scheme (when to use -- and when not)
;; TODO copy the gitreviewless code into gerrit.el file
;; TODO provide a C-u version for gerrit-download-new, which also asks for the PS number
;; TODO defvar for turning off .gitreview parsing. I would rather not parse it.
;;         use "origin" as the remote if this parsing is turned off
;; TODO if git-review parsing is turned off - how do we determine the upstream branch then?
;;         if the local branch has an upstream configured -> use it
;;         if it doesn't -> ask the user (magit-read-string)
;;         Note:
;;         git checkout -b fb -t origin/version0.2  # this can be used for creating
;;         a local branch fb that is based on origin/version0.2 and which tracks
;;         origin/version0.2 (=upstream)
;; TODO write some unit tests that create git repos and test elisp functions
;; TODO use gerrit-magit-process-buffer-add-item for:
;;       setting the assignee:
;;            section name: changenr and assignee
;;            section body: maybe rest output? especially useful if there is an error
;; TODO download gerrit change on top of current branch (like cherry-pick)
;; TODO download command that lists only the changes in the current branch
;; TODO check (in advance) that the uploaded commits contain a Change-Id
;;       see (magit-insert-log "@{upstream}.." args)
;;       for commit in $(git rev-list 15044377058d2481e1d9a1334c71037598f9a006..HEAD); do
;;           git log --format=%B -r $commit -n1; done
;;       or check if 'Change-Id string is in the output of
;;           git log --format=%B -r start-sha1..end-sha1
;;       how do I determine the start-sha1?
;;           -> use  branchname@{u}
;; TODO upload: before uploading a change check the sha1 of the latest commit and check
;;              if it is alredy a change on gerrit with this sha1
;; TODO upload: always-rebase by default? git-review always rebases by default
;;              but for merge commits it must not rebase automatically
;; TODO use transient for upload form
;; (defun test-function (&optional args)
;;   (interactive
;;    (list (transient-args 'test-transient)))
;;   (message "args: %s" args))

;; (define-transient-command test-transient ()
;;   "Test Transient Title"
;;   ["Arguments"
;;    ("s" "Switch" "--switch")
;;    ("a" "Another param" "--another=")]
;;   ["Actions"
;;    ("d" "Action d" test-function)])

;; (test-transient)
;; -> The test-transient allows one to cycle over all settings C-M-p / C-M-n
;; and also over all the infix history

;; TODO gerrit-display-recent-topic-comments
;; user enters a topicname
;; user sees a list of comments with the following format
;;  header: project
;;  date (relative to current time): commenter
;;    comment
;; allow the user to specify a filter function
;;   filter out robot comment, filter our comments older than X days,..



;;; Code:

(require 's)
(require 'seq)
(require 'cl-lib)
(require 'hydra)
(require 'magit)

(require 'gerrit)
(require 'gerrit-rest)

(defun gerrit-download-format-change (change)
  (concat
   (propertize (number-to-string (alist-get '_number change)) 'face 'magit-hash)
   " "
   (propertize (alist-get 'branch change) 'face 'magit-branch-remote)
   " "
   (propertize (alist-get 'subject change) 'face 'magit-section-highlight)))

(defun gerrit-download--get-refspec (change-metadata)
  "Return the refspec of a gerrit change from CHANGE-METADATA.

This refspec is a string of the form 'refs/changes/xx/xx/x'.
"
  ;; this is important for determining the refspec needed for
  ;; git-fetch
  ;; change-ref is e.g. "refs/changes/16/35216/2"
  (let* ((revisions (alist-get 'revisions change-metadata))
         (revision (alist-get 'current_revision change-metadata)))
    (gerrit--alist-get-recursive (intern revision) 'ref revisions)))

(defun gerrit--get-tracked (branch)
  "Get upstream-remote and upstream-branch of a local BRANCH."
  ;; Note that magit-get-upstream-branch returns a propertized string
  (let ((tracked (magit-get-upstream-branch branch)))
    (s-split-up-to "/" tracked 1 t)))

(defun gerrit--download-change (change-metadata)
  ;; to see what git-review does under the hood - see:
  ;; strace -z -f -e execve git-review -d 3591
  (let* ((change-nr (alist-get '_number change-metadata))
         (change-branch (alist-get 'branch change-metadata))
         (change-topic (or (alist-get 'topic change-metadata)
                           (number-to-string change-nr)))
         (change-owner (alist-get (gerrit--alist-get-recursive
                                   'owner '_account_id change-metadata)
                                  gerrit--accounts-alist))
         (local-branch (format "review/%s/%s"
                               ;; change-owner is 'escaped' by git-review (_
                               ;; instead of . is used). git-review uses
                               ;; re.sub(r'\W+', "_", ownername), which was
                               ;; introduced 2011 (commit 08bd9c). I don't
                               ;; know why they did it.
                               (replace-regexp-in-string "\\W+" "_" change-owner)
                               change-topic)))

    ;;TODO
    ;; this next call doesn't work if the authorization doesn't work
    ;; (e.g. if ssh-add was not called)
    (magit-call-git "fetch" (gerrit-get-remote) (gerrit-download--get-refspec change-metadata))

    (if-let* ((local-ref (concat "refs/heads/" local-branch))
              (branch-exists (magit-git-success "show-ref" "--verify" "--quiet" local-ref)))
        (progn
          ;; since local-branch exists, gerrit--get-tracked never returns nil
          (seq-let (tracked-remote tracked-branch) (gerrit--get-tracked local-branch)
            (unless (and (equal tracked-remote (gerrit-get-remote))
                         (equal tracked-branch change-branch))
              (error "Branch tracking incompatibility: Tracking %s/%s instead of %s/%s"
                     tracked-remote tracked-branch
                     (gerrit-get-remote) change-branch)))
          (magit-run-git "checkout" local-branch)
          (magit-run-git "reset" "--hard" "FETCH_HEAD"))
      ;;
      (magit-branch-and-checkout local-branch "FETCH_HEAD")
      ;; set upstream here (see checkout_review function in cmd.py)
      ;; this upstream branch is needed for rebasing
      (magit-run-git "branch"
                     "--set-upstream-to" (format "%s/%s" (gerrit-get-remote) change-branch)
                     local-branch))))

(defun gerrit-download-new-v3 ()
  "Download change from the gerrit server."
  (interactive)
  (gerrit--init-accounts)
  (let* ((open-changes
          (seq-map #'gerrit-download-format-change (gerrit-rest-change-query
                                                    (concat "status:open project:"
                                                            (gerrit-get-current-project)))))
         (selected-line (completing-read
                         "Download Change: " open-changes nil nil))
         (changenr (car (s-split " " (s-trim selected-line))))

         ;; the return value of `gerrit-rest-change-query` contains the
         ;; current revision, but not the one of `gerrit-rest-change-get`.
         (change-metadata (car (gerrit-rest-change-query changenr))))

    (gerrit--download-change change-metadata)))

(defun gerrit--ensure-commit-msg-hook-exists ()
  "Create a commit-msg hook, if it doesn't exist."
  (let ((hook-file (magit-git-dir "hooks/commit-msg")))
    (unless (file-exists-p hook-file)
      (message "downloading commit-msg hook file")
      (url-copy-file
       (concat "https://" gerrit-host  "/tools/hooks/commit-msg") hook-file)
      (set-file-modes hook-file #o755))))

(defun gerrit-push-and-assign (assignee &rest push-args)
  "Execute Git push with PUSH-ARGS and assign changes to ASSIGNEE.

A section in the respective process buffer is created."
  (interactive)
  (progn
    (apply #'magit-run-git-async "push" push-args)
    (set-process-sentinel
     magit-this-process
     (lambda (process event)
       (when (memq (process-status process) '(exit signal))
         (when (buffer-live-p (process-buffer process))
           (with-current-buffer (process-buffer process)
             (when-let ((section (get-text-property (point) 'magit-section))
                        (output (buffer-substring-no-properties
                                 (oref section content)
                                 (oref section end))))
               (if (not (zerop (process-exit-status process)))
                   ;; error
                   (magit-process-sentinel process event)

                 ;; success
                 (process-put process 'inhibit-refresh t)

                 ;; parse the output of "git push" and extract the change numbers. This
                 ;; information is used for setting the specified assignee
                 ;; Alternatively we could perform a gerrit query with owner:me and set the
                 ;; assignee for the latest change(s).
                 (unless (equal "" assignee)
                   (if-let ((matched-changes (s-match-strings-all "/\\+/[0-9]+" output)))
                       (seq-do (lambda (x) (let ((changenr (s-chop-prefix "/+/" (car x))))
                                        (message "Setting assignee of %s to %s" changenr assignee)
                                        (gerrit-rest-change-set-assignee changenr assignee)
                                        (gerrit-magit-process-buffer-add-item
                                         (format "Assignee of change %s was set to %s" changenr assignee)
                                         "set-assignee" changenr)))
                               matched-changes)))
                 (magit-process-sentinel process event))))))))))

(defun gerrit-upload--get-refspec ()
  (concat "refs/for/" (gerrit-get-upstream-branch)))

;; The transient history is saved when the kill-emacs-hook is run, which is
;; run when (kill-emacs) is called. Make sure that you run kill-emacs when
;; you stop emacs (or restart an emacs (systemd) service).  Note that
;; (transient-save-history) is the function that saves the history.

;; There is a limit for the number of entries saved per option(?) into the
;; history file, which is 10 by default. I think it makes sense to increase
;; this value to at least 50 (only 10 saved topic names may not be enough).

;; The `history` in the reader callbacks is updated after the reader
;; callback was called.

;; The history file contains both the history elements of "submitted"
;; settings (where the action was called) as well as the history of the
;; individual options independent whether the qction was called or not (if a
;; reader is specified, the history parameter needs to be updated for this
;; to work!).

(defun gerrit-upload:--action (&optional args)
  "Push the current changes/commits to the gerrit server and set metadata."
  (interactive
   (list (transient-args 'gerrit-upload-transient)))

  (gerrit--ensure-commit-msg-hook-exists)
  ;; TODO check that all to-be-uploaded commits have a changeid line

  (let (assignee
        push-opts
        (remote (gerrit-get-remote))
        (refspec (gerrit-upload--get-refspec)))
    ;; there are a bunch of push options that are supported by gerrit:
    ;; https://gerrit-review.googlesource.com/Documentation/user-upload.html#push_options

    ;; I don't like this handling of transient-args, maybe transient can
    ;; pass alists to gerrit-upload--action istead of a list os strings
    (cl-loop for arg in args do
             (cond ((s-starts-with? "reviewers=" arg)
                    (cl-loop for reviewer in (s-split "," (s-chop-prefix "reviewers=" arg)) do
                             ;; TODO check that reviewers are valid (by checking that all
                             ;; reviewers don't contain a white-space)
                             (push (concat "r=" reviewer) push-opts)))
                   ((s-starts-with? "assignee=" arg)
                    (setq assignee (s-chop-prefix "assignee=" arg)))
                   ((s-starts-with? "topic=" arg)
                    (push  arg push-opts))
                   ((string= "ready" arg)
                    (push "ready" push-opts))
                   ((string= "wip" arg)
                    (push "wip" push-opts))
                   (t
                    (error (format "no match for arg: %s" arg)))))

    (when push-opts
      (setq refspec (concat refspec "%" (s-join "," push-opts))))

    (gerrit-push-and-assign
     assignee
     "--no-follow-tags"
     remote
     (concat "HEAD:"  refspec))))

(define-transient-command gerrit-upload-transient ()
  "Transient used for uploading changes to gerrit"
  ["Arguments"
   (gerrit-upload:--reviewers)
   (gerrit-upload:--assignee)
   ("w" "Work in Progress" "wip")
   ("v" "Ready for Review" "ready")
   (gerrit-upload:--topic)
  ]
  ["Actions"
   ("u" "Upload" gerrit-upload:--action)])

;; TODO ask on github why a subclass of transient option is needed.
(defclass gerrit-multivalue-option (transient-option) ())

(cl-defmethod transient-infix-value ((obj gerrit-multivalue-option))
  "Return (concat ARGUMENT VALUE) or nil.

ARGUMENT and VALUE are the values of the respective slots of OBJ.
If VALUE is nil, then return nil.  VALUE may be the empty string,
which is not the same as nil."
  (when-let ((value (oref obj value)))
    (if (listp value) (setq value (string-join value ",")))
    (concat (oref obj argument) value)))

(transient-define-argument gerrit-upload:--reviewers ()
  :description "Reviewers"
  :class 'gerrit-multivalue-option
  :key "r"
  :argument "reviewers="
  ;; :format " %k %v"
  :multi-value t
  :reader 'gerrit-upload:--read-reviewers)

(defun gerrit-upload:--read-reviewers (prompt _initial-input history)
  (gerrit--init-accounts)
  ;; FIXME the sorting order here seems to be different than the one used in
  ;; completing-read! Maybe this is just an ivy issue
  (completing-read-multiple
   prompt
   (seq-map #'cdr gerrit--accounts-alist) ;; usernames
   nil
   nil
   nil))

(transient-define-argument gerrit-upload:--assignee ()
  :description "Assignee"
  :class 'transient-option
  :key "a"
  :argument "assignee="
  :reader 'gerrit-upload:--read-assignee)

(transient-define-argument gerrit-upload:--topic ()
  :description "Topic"
  :class 'transient-option
  :key "t"
  :argument "topic="
  :reader 'gerrit-upload:--read-topic)

(defun gerrit-upload:--read-assignee (prompt _initial-input history)
  (gerrit--init-accounts)
  ;; (gerrit--read-assignee) this doesn't update the history

  ;; using the history here doesn't have an effect (maybe it does, but for
  ;; ivy-completing-read it doesn't)
  (completing-read
   prompt
   (seq-map #'cdr gerrit--accounts-alist) ;; usernames
   nil ;; predicate
   t ;; require match
   nil ;; initial ;; Maybe it makes sense to use the last/first history element here
   history ;; hist (output only?)
   ;; def
   nil))

(defun gerrit-upload:--read-topic (prompt _initial-input history)
  ;; (message "GRT: %s %s %s" prompt _initial-input (symbol-value history))
  ;; (gerrit-upload-completing-set
  ;;                          "Topic: "
  ;;                          gerrit-upload-topic-history))

  (completing-read
   prompt
   (symbol-value history)
   nil nil nil
   history))

(defalias 'gerrit-upload-new #'gerrit-upload-transient)

(provide 'gerrit-gitreviewless)
;;; gerrit-gitreviewless.el ends here
