;;; agent-shell-claude-agents-tracker.el --- Track subagents spawned by Claude Code -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Wanderson Ferreira
;; URL: https://github.com/wandersoncferreira/agent-shell-claude-agents-tracker
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.33.1"))
;; Keywords: convenience, tools, ai

;; This file is not part of GNU Emacs.

;;; Commentary:

;; agent-shell-claude-agents-tracker tracks and displays subagents spawned by Claude Code
;; when using the Agent tool or TeamCreate within an agent-shell session.
;;
;; Features:
;; - Detects Agent tool invocations via tool-call-update events
;; - Monitors ~/.claude/teams/ for team creation
;; - Displays subagents in a sidebar buffer
;; - Shows mode-line indicator with running/total counts
;;
;; Quick start:
;;    (use-package agent-shell-claude-agents-tracker
;;      :after agent-shell
;;      :config
;;      (agent-shell-claude-agents-tracker-mode 1))

;;; Code:

(require 'agent-shell)
(require 'filenotify)
(require 'json)
(require 'cl-lib)

(defgroup agent-shell-claude-agents-tracker nil
  "Track subagents spawned by Claude Code."
  :group 'agent-shell
  :prefix "agent-shell-claude-agents-tracker-")

;;; Configuration

(defcustom agent-shell-claude-agents-tracker-auto-subscribe t
  "Automatically subscribe to new agent-shell buffers."
  :type 'boolean
  :group 'agent-shell-claude-agents-tracker)

(defcustom agent-shell-claude-agents-tracker-show-mode-line t
  "Show subagent count in mode-line."
  :type 'boolean
  :group 'agent-shell-claude-agents-tracker)

(defcustom agent-shell-claude-agents-tracker-watch-teams t
  "Watch ~/.claude/teams/ for team files."
  :type 'boolean
  :group 'agent-shell-claude-agents-tracker)

(defcustom agent-shell-claude-agents-tracker-sidebar-width 56
  "Width of the subagent tracker buffer."
  :type 'integer
  :group 'agent-shell-claude-agents-tracker)

(defcustom agent-shell-claude-agents-tracker-refresh-interval 5
  "Seconds between auto-refresh of tracker display."
  :type 'integer
  :group 'agent-shell-claude-agents-tracker)

(defcustom agent-shell-claude-agents-tracker-inbox-poll-interval 5
  "Seconds between polling team inboxes for new messages."
  :type 'integer
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-running
  '((t :inherit success :weight bold))
  "Face for running subagents."
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-completed
  '((t :inherit shadow :slant italic))
  "Face for completed subagents."
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-failed
  '((t :inherit error :weight bold))
  "Face for failed subagents."
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-header
  '((t :weight bold :height 1.1))
  "Face for headers in tracker buffer."
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-parent
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for parent buffer names."
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-type
  '((t :inherit font-lock-type-face))
  "Face for subagent type."
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-meta
  '((t :inherit shadow))
  "Face for metadata (duration, timing)."
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-waiting
  '((t :inherit warning :weight bold))
  "Face for waiting for response indicator."
  :group 'agent-shell-claude-agents-tracker)

;;; State Variables

(defvar agent-shell-claude-agents-tracker--agents (make-hash-table :test 'equal)
  "Hash table mapping tool-call-id to subagent info plist.
Each plist contains:
  :tool-call-id - unique identifier
  :parent-buffer - agent-shell buffer that spawned it
  :name - agent name (if provided)
  :type - subagent_type (Explore, Plan, etc.)
  :prompt - the task/prompt given
  :description - short description
  :status - running/completed/failed
  :started-at - timestamp
  :completed-at - timestamp (when finished)
  :run-in-background - boolean
  :output - the output/result when completed
  :expanded - whether output is expanded in UI")

(defvar agent-shell-claude-agents-tracker--expanded-agents (make-hash-table :test 'equal)
  "Hash table tracking which agents have expanded output view.")

(defvar agent-shell-claude-agents-tracker--teams (make-hash-table :test 'equal)
  "Hash table mapping team-name to team info.")

(defvar agent-shell-claude-agents-tracker--subscriptions nil
  "Alist of (buffer . subscription-token) for cleanup.")

(defvar agent-shell-claude-agents-tracker--file-watchers nil
  "List of file-notify descriptors.")

(defvar agent-shell-claude-agents-tracker--refresh-timer nil
  "Timer for auto-refresh.")

(defvar agent-shell-claude-agents-tracker--inbox-timer nil
  "Timer for polling inbox messages.")

(defvar agent-shell-claude-agents-tracker--seen-messages (make-hash-table :test 'equal)
  "Hash table tracking seen message timestamps per inbox file.
Keys are inbox file paths, values are the count of messages already seen.")

(defvar agent-shell-claude-agents-tracker--agent-messages (make-hash-table :test 'equal)
  "Hash table mapping agent name to list of messages received from that agent.
Each message is a plist with :from :text :summary :timestamp :read.")

(defvar agent-shell-claude-agents-tracker--expanded-messages (make-hash-table :test 'equal)
  "Hash table tracking which agents have expanded messages view.")

(defvar agent-shell-claude-agents-tracker--buffer-name "*Code Agents*"
  "Name of the tracker sidebar buffer.")

(defvar agent-shell-claude-agents-tracker--message-buffer-name "*Claude Message*"
  "Name of the full message viewer buffer.")

(defvar agent-shell-claude-agents-tracker--return-position nil
  "Saved position to return to in the tracker buffer.")

(defvar agent-shell-claude-agents-tracker--saved-window-config nil
  "Saved window configuration to restore when closing message viewer.")

(defvar agent-shell-claude-agents-tracker--collapsed-messages (make-hash-table :test 'equal)
  "Hash table tracking which messages are collapsed.
Keys are \"agent-name:message-index\", values are t if collapsed.")

(defvar agent-shell-claude-agents-tracker--waiting-for-response (make-hash-table :test 'equal)
  "Hash table tracking agents we're waiting for a response from.
Keys are agent names, values are the timestamp when we started waiting.")

;;; Event Handling

(defun agent-shell-claude-agents-tracker--get-raw-input-field (raw-input field)
  "Get FIELD from RAW-INPUT, trying both string and symbol keys."
  (when raw-input
    (or (cdr (assoc field raw-input))           ; string key (from json-parse-string)
        (cdr (assq (intern field) raw-input))))) ; symbol key (fallback)

(defun agent-shell-claude-agents-tracker--extract-text-content (content)
  "Extract plain text from CONTENT which may be a string or structured object.
The content from ACP can be:
- A plain string
- A vector of content blocks like [((type . \"content\") (content (type . \"text\") (text . \"...\")))]"
  (cond
   ((null content) nil)
   ((stringp content) content)
   ((vectorp content)
    ;; It's a vector of content blocks - extract text from each
    (mapconcat
     (lambda (block)
       (let* ((block-content (or (cdr (assoc "content" block))
                                 (cdr (assq 'content block))))
              (text (or (cdr (assoc "text" block-content))
                        (cdr (assq 'text block-content))
                        ;; Sometimes text is directly in block
                        (cdr (assoc "text" block))
                        (cdr (assq 'text block)))))
         (or text "")))
     content
     "\n"))
   ((listp content)
    ;; It might be a single content block as an alist
    (let* ((block-content (or (cdr (assoc "content" content))
                              (cdr (assq 'content content))))
           (text (or (cdr (assoc "text" block-content))
                     (cdr (assq 'text block-content))
                     (cdr (assoc "text" content))
                     (cdr (assq 'text content)))))
      (or text (format "%S" content))))
   (t (format "%S" content))))

(defun agent-shell-claude-agents-tracker--is-agent-tool-p (title raw-input)
  "Return non-nil if this tool call is an Agent tool invocation.
Check for exact title match or presence of subagent_type in RAW-INPUT."
  (or
   ;; Exact title match for Agent tool
   (string= title "Agent")
   ;; Or has subagent_type field (unique to Agent tool)
   (agent-shell-claude-agents-tracker--get-raw-input-field raw-input "subagent_type")))

(defun agent-shell-claude-agents-tracker--on-tool-call (event)
  "Handle tool-call-update EVENT, detect Agent tool invocations."
  (let* ((data (cdr (assq :data event)))
         (tool-call-id (cdr (assq :tool-call-id data)))
         (tool-call (cdr (assq :tool-call data))))
    (when tool-call
      (let* ((title (or (cdr (assq :title tool-call)) ""))
             (status (or (cdr (assq :status tool-call)) ""))
             (raw-input (cdr (assq :raw-input tool-call)))
             (description (cdr (assq :description tool-call)))
             (content (cdr (assq :content tool-call))))
        ;; Only track actual Agent tool invocations
        (when (agent-shell-claude-agents-tracker--is-agent-tool-p title raw-input)
          (agent-shell-claude-agents-tracker--register-subagent
           :tool-call-id tool-call-id
           :parent-buffer (current-buffer)
           :name (agent-shell-claude-agents-tracker--get-raw-input-field raw-input "name")
           :type (agent-shell-claude-agents-tracker--get-raw-input-field raw-input "subagent_type")
           :prompt (agent-shell-claude-agents-tracker--get-raw-input-field raw-input "prompt")
           :description (or (agent-shell-claude-agents-tracker--get-raw-input-field raw-input "description")
                            description title)
           :status status
           :output (agent-shell-claude-agents-tracker--extract-text-content content)
           :run-in-background (agent-shell-claude-agents-tracker--get-raw-input-field
                               raw-input "run_in_background")))))))

(cl-defun agent-shell-claude-agents-tracker--register-subagent
    (&key tool-call-id parent-buffer name type prompt description status output run-in-background)
  "Register or update a subagent with the given properties."
  (let ((existing (gethash tool-call-id agent-shell-claude-agents-tracker--agents))
        (now (current-time)))
    (if existing
        ;; Update existing entry
        (progn
          (plist-put existing :status status)
          (when output
            (plist-put existing :output output))
          ;; Update type/description if they were unknown and now available
          (when (and type (not (equal type "unknown"))
                     (equal (plist-get existing :type) "unknown"))
            (plist-put existing :type type))
          (when (and description
                     (or (null (plist-get existing :description))
                         (equal (plist-get existing :description) "Agent")))
            (plist-put existing :description description))
          (when (and name (null (plist-get existing :name)))
            (plist-put existing :name name))
          (when (member status '("completed" "failed"))
            (plist-put existing :completed-at now))
          (puthash tool-call-id existing agent-shell-claude-agents-tracker--agents))
      ;; Create new entry
      (puthash tool-call-id
               (list :tool-call-id tool-call-id
                     :parent-buffer parent-buffer
                     :name name
                     :type (or type "unknown")
                     :prompt prompt
                     :description description
                     :status status
                     :started-at now
                     :completed-at nil
                     :output output
                     :run-in-background run-in-background)
               agent-shell-claude-agents-tracker--agents))
    ;; Refresh display
    (agent-shell-claude-agents-tracker--refresh-display)))

;;; Subscription Management

(defun agent-shell-claude-agents-tracker--subscribe-to-buffer (buffer)
  "Subscribe to tool-call-update events in BUFFER."
  (when (and (buffer-live-p buffer)
             (not (assq buffer agent-shell-claude-agents-tracker--subscriptions)))
    (with-current-buffer buffer
      (when (derived-mode-p 'agent-shell-mode)
        (let ((token (agent-shell-subscribe-to
                      :shell-buffer buffer
                      :event 'tool-call-update
                      :on-event #'agent-shell-claude-agents-tracker--on-tool-call)))
          (push (cons buffer token) agent-shell-claude-agents-tracker--subscriptions))))))

(defun agent-shell-claude-agents-tracker--unsubscribe-from-buffer (buffer)
  "Unsubscribe from events in BUFFER."
  (when-let ((entry (assq buffer agent-shell-claude-agents-tracker--subscriptions)))
    (when (functionp 'agent-shell-unsubscribe)
      (agent-shell-unsubscribe :subscription (cdr entry)))
    (setq agent-shell-claude-agents-tracker--subscriptions
          (assq-delete-all buffer agent-shell-claude-agents-tracker--subscriptions))))

(defun agent-shell-claude-agents-tracker--on-buffer-created ()
  "Hook function to subscribe to newly created agent-shell buffers."
  (when agent-shell-claude-agents-tracker-auto-subscribe
    (agent-shell-claude-agents-tracker--subscribe-to-buffer (current-buffer))))

;;; Team File Watching

(defun agent-shell-claude-agents-tracker--teams-dir ()
  "Return the Claude teams directory path."
  (expand-file-name "~/.claude/teams/"))

(defun agent-shell-claude-agents-tracker--tasks-dir ()
  "Return the Claude tasks directory path."
  (expand-file-name "~/.claude/tasks/"))

(defun agent-shell-claude-agents-tracker--on-team-change (event)
  "Handle file change EVENT in teams directory."
  (let ((action (nth 1 event))
        (file (nth 2 event)))
    (when (and file (string-suffix-p "config.json" file))
      (pcase action
        ((or 'created 'changed)
         (agent-shell-claude-agents-tracker--parse-team-config file))
        ('deleted
         (let ((team-name (file-name-base (directory-file-name
                                           (file-name-directory file)))))
           (remhash team-name agent-shell-claude-agents-tracker--teams)))))
    (agent-shell-claude-agents-tracker--refresh-display)))

(defun agent-shell-claude-agents-tracker--parse-team-config (file)
  "Parse team config FILE and update team tracking."
  (when (file-exists-p file)
    (condition-case err
        (let* ((json-object-type 'alist)
               (json-array-type 'list)
               (config (json-read-file file))
               (team-name (file-name-base (directory-file-name
                                           (file-name-directory file))))
               (members (cdr (assq 'members config))))
          (puthash team-name
                   (list :name team-name
                         :config-file file
                         :members members
                         :updated-at (current-time))
                   agent-shell-claude-agents-tracker--teams))
      (error (message "agent-shell-claude-agents-tracker: Error parsing %s: %s" file err)))))

(defun agent-shell-claude-agents-tracker--start-file-watchers ()
  "Start watching team/task directories."
  (agent-shell-claude-agents-tracker--stop-file-watchers)
  (when agent-shell-claude-agents-tracker-watch-teams
    (let ((teams-dir (agent-shell-claude-agents-tracker--teams-dir)))
      (when (file-directory-p teams-dir)
        ;; Watch the teams directory
        (push (file-notify-add-watch teams-dir
                                     '(change)
                                     #'agent-shell-claude-agents-tracker--on-team-change)
              agent-shell-claude-agents-tracker--file-watchers)
        ;; Parse existing team configs
        (dolist (dir (directory-files teams-dir t "^[^.]"))
          (when (file-directory-p dir)
            (let ((config (expand-file-name "config.json" dir)))
              (when (file-exists-p config)
                (agent-shell-claude-agents-tracker--parse-team-config config)))))))))

(defun agent-shell-claude-agents-tracker--stop-file-watchers ()
  "Stop all file watchers."
  (dolist (descriptor agent-shell-claude-agents-tracker--file-watchers)
    (ignore-errors (file-notify-rm-watch descriptor)))
  (setq agent-shell-claude-agents-tracker--file-watchers nil))

;;; Display / UI

(defun agent-shell-claude-agents-tracker--format-time-ago (time)
  "Format TIME as relative time string."
  (if time
      (let ((seconds (float-time (time-subtract (current-time) time))))
        (cond
         ((< seconds 60) (format "%ds ago" (round seconds)))
         ((< seconds 3600) (format "%dm ago" (round (/ seconds 60))))
         ((< seconds 86400) (format "%dh ago" (round (/ seconds 3600))))
         (t (format-time-string "%Y-%m-%d" time))))
    "unknown"))

(defun agent-shell-claude-agents-tracker--format-duration (start end)
  "Format duration between START and END times."
  (if (and start end)
      (let ((seconds (float-time (time-subtract end start))))
        (cond
         ((< seconds 60) (format "%ds" (round seconds)))
         ((< seconds 3600) (format "%dm %ds" (/ (round seconds) 60) (mod (round seconds) 60)))
         (t (format "%dh %dm" (/ (round seconds) 3600) (mod (/ (round seconds) 60) 60)))))
    ""))

(defun agent-shell-claude-agents-tracker--format-duration-compact (start end)
  "Format duration between START and END times in compact form (e.g., 2m, 45s)."
  (if (and start end)
      (let ((seconds (float-time (time-subtract end start))))
        (cond
         ((< seconds 60) (format "%ds" (round seconds)))
         ((< seconds 3600) (format "%dm" (round (/ seconds 60))))
         (t (format "%dh" (round (/ seconds 3600))))))
    ""))

(defun agent-shell-claude-agents-tracker--format-elapsed-compact (start)
  "Format elapsed time since START in compact form."
  (if start
      (agent-shell-claude-agents-tracker--format-duration-compact start (current-time))
    ""))

(defun agent-shell-claude-agents-tracker--status-indicator (status)
  "Return a single-character status indicator for STATUS."
  (pcase status
    ("running" "●")
    ("completed" "✓")
    ("failed" "✗")
    (_ "○")))

(defun agent-shell-claude-agents-tracker--truncate-description (desc max-len)
  "Truncate DESC to MAX-LEN characters, adding ellipsis if needed."
  (if (and desc (> (length desc) max-len))
      (concat (substring desc 0 (- max-len 3)) "...")
    (or desc "")))

(defun agent-shell-claude-agents-tracker--status-face (status)
  "Return face for STATUS."
  (pcase status
    ("running" 'agent-shell-claude-agents-tracker-running)
    ("completed" 'agent-shell-claude-agents-tracker-completed)
    ("failed" 'agent-shell-claude-agents-tracker-failed)
    (_ 'default)))

(defcustom agent-shell-claude-agents-tracker-output-max-lines 10
  "Maximum lines of prompt/output to show when expanded."
  :type 'integer
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-output
  '((t :inherit default))
  "Face for subagent output text."
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-section-label
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for section labels (Prompt, Output)."
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-expand-button
  '((t :inherit link :weight bold))
  "Face for expand/collapse buttons."
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-teammate
  '((t :inherit success :weight bold))
  "Face for teammate names."
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-teammate-id
  '((t :inherit shadow :slant italic))
  "Face for teammate IDs."
  :group 'agent-shell-claude-agents-tracker)

(defun agent-shell-claude-agents-tracker--truncate-output (output max-lines)
  "Truncate OUTPUT to MAX-LINES, adding indicator if truncated."
  (if (null output)
      nil
    (let* ((lines (split-string output "\n"))
           (total (length lines)))
      (if (<= total max-lines)
          output
        (concat (string-join (seq-take lines max-lines) "\n")
                (format "\n... (%d more lines)" (- total max-lines)))))))

(defface agent-shell-claude-agents-tracker-unread
  '((t :inherit warning :weight bold))
  "Face for unread message indicator."
  :group 'agent-shell-claude-agents-tracker)

(defun agent-shell-claude-agents-tracker--insert-subagent (agent is-last &optional team-name member-name)
  "Insert AGENT info into buffer. IS-LAST indicates if it's the last in group.
TEAM-NAME and MEMBER-NAME are optional for team members to enable messaging.
Uses compact one-line format when collapsed, full details when expanded."
  (let* ((tool-call-id (plist-get agent :tool-call-id))
         (agent-name (or member-name (plist-get agent :name)))
         (status (plist-get agent :status))
         (type (plist-get agent :type))
         (description (plist-get agent :description))
         (prompt (plist-get agent :prompt))
         (started-at (plist-get agent :started-at))
         (completed-at (plist-get agent :completed-at))
         (output (plist-get agent :output))
         ;; Check for messages from this agent
         (messages (when agent-name
                     (gethash agent-name agent-shell-claude-agents-tracker--agent-messages)))
         (has-unread (and agent-name
                          (agent-shell-claude-agents-tracker--agent-has-unread-p agent-name)))
         (unread-count (when has-unread
                         (agent-shell-claude-agents-tracker--agent-unread-count agent-name)))
         ;; Use agent-name for expand key if no tool-call-id
         (expand-key (or tool-call-id agent-name))
         (expanded (and expand-key
                        (gethash expand-key agent-shell-claude-agents-tracker--expanded-agents)))
         (is-waiting (and agent-name
                          (gethash agent-name agent-shell-claude-agents-tracker--waiting-for-response)))
         (has-more (or prompt output messages is-waiting))
         (prefix "  ")
         (start-pos (point))
         ;; Compact format components
         (status-indicator (agent-shell-claude-agents-tracker--status-indicator status))
         (compact-duration (if completed-at
                               (agent-shell-claude-agents-tracker--format-duration-compact started-at completed-at)
                             (agent-shell-claude-agents-tracker--format-elapsed-compact started-at)))
         (compact-desc (agent-shell-claude-agents-tracker--truncate-description description 30)))
    (if expanded
        ;; === EXPANDED VIEW: Full details ===
        (progn
          ;; Header line
          (insert prefix)
          (insert-text-button "▼"
                              'face 'agent-shell-claude-agents-tracker-expand-button
                              'action (lambda (button)
                                        (agent-shell-claude-agents-tracker-toggle-output
                                         (button-get button 'expand-key)))
                              'expand-key expand-key
                              'help-echo "Click to collapse")
          (insert " ")
          (insert (propertize status-indicator
                              'face (agent-shell-claude-agents-tracker--status-face status)))
          (insert " ")
          (insert (propertize (or type "Agent") 'face 'agent-shell-claude-agents-tracker-type))
          (when has-unread
            (insert " ")
            (insert (propertize (format "[%d]" unread-count)
                                'face 'agent-shell-claude-agents-tracker-unread)))
          (when is-waiting
            (insert " ")
            (insert (propertize "⏳ Waiting for response..." 'face 'agent-shell-claude-agents-tracker-waiting)))
          (insert "\n")
          ;; Full description
          (when description
            (insert prefix "  ")
            (insert description)
            (insert "\n"))
          ;; Timing info
          (when started-at
            (insert prefix "  ")
            (if completed-at
                (insert (propertize (format "Duration: %s"
                                            (agent-shell-claude-agents-tracker--format-duration started-at completed-at))
                                    'face 'agent-shell-claude-agents-tracker-meta))
              (insert (propertize (format "Started: %s"
                                          (agent-shell-claude-agents-tracker--format-time-ago started-at))
                                  'face 'agent-shell-claude-agents-tracker-meta)))
            (insert "\n"))
          ;; Send message button (if team member)
          (when (and team-name member-name
                     (not (string-empty-p (or team-name "")))
                     (not (string-empty-p (or member-name ""))))
            (insert prefix "  ")
            (insert-text-button "✉ Send message"
                                'face 'agent-shell-claude-agents-tracker-expand-button
                                'action (lambda (button)
                                          (agent-shell-claude-agents-tracker-message-teammate
                                           (button-get button 'teammate-name)
                                           (button-get button 'team-name)))
                                'teammate-name member-name
                                'team-name team-name
                                'help-echo (format "Send message to %s" member-name))
            (insert "\n"))
          ;; Mark messages as read
          (when agent-name
            (agent-shell-claude-agents-tracker--mark-messages-read agent-name))
          ;; Separator
          (insert prefix "  ")
          (insert (propertize (make-string 40 ?─) 'face 'agent-shell-claude-agents-tracker-meta))
          (insert "\n")
          ;; Show messages if available
          (when messages
            (insert prefix "  ")
            (insert (propertize (format "Messages (%d)" (length messages))
                                'face 'agent-shell-claude-agents-tracker-section-label))
            (insert "\n")
            (let ((msg-index 0))
              (dolist (msg messages)
                (let* ((text (plist-get msg :text))
                       (summary (plist-get msg :summary))
                       (timestamp (plist-get msg :timestamp))
                       (msg-key (format "%s:%d" (or agent-name "unknown") msg-index))
                       (msg-collapsed (gethash msg-key agent-shell-claude-agents-tracker--collapsed-messages))
                       (msg-start-pos (point)))
                  (insert prefix "    ")
                  ;; Collapse/expand button
                  (insert-text-button (if msg-collapsed "▶" "▼")
                                      'face 'agent-shell-claude-agents-tracker-expand-button
                                      'action (lambda (button)
                                                (agent-shell-claude-agents-tracker-toggle-message
                                                 (button-get button 'message-key)))
                                      'message-key msg-key
                                      'help-echo "Click to toggle message")
                  (insert " ")
                  (when timestamp
                    (insert (propertize (format "[%s] " timestamp)
                                        'face 'agent-shell-claude-agents-tracker-inbox-timestamp)))
                  (when summary
                    (insert (propertize summary 'face 'agent-shell-claude-agents-tracker-meta)))
                  (insert "\n")
                  ;; Only show content if not collapsed
                  (unless msg-collapsed
                    (when text
                      (let* ((truncated (agent-shell-claude-agents-tracker--truncate-output
                                         text agent-shell-claude-agents-tracker-output-max-lines))
                             (is-truncated (agent-shell-claude-agents-tracker--text-truncated-p
                                            text agent-shell-claude-agents-tracker-output-max-lines)))
                        (dolist (line (split-string truncated "\n"))
                          (insert prefix "      ")
                          (insert (propertize line 'face 'agent-shell-claude-agents-tracker-output))
                          (insert "\n"))
                        ;; Add "View full" button if truncated
                        (when is-truncated
                          (insert prefix "      ")
                          (insert-text-button "📄 View full"
                                              'face 'agent-shell-claude-agents-tracker-expand-button
                                              'action (lambda (button)
                                                        (agent-shell-claude-agents-tracker-view-full-message
                                                         (button-get button 'agent-name)
                                                         (button-get button 'full-text)
                                                         (button-get button 'summary)
                                                         (button-get button 'timestamp)))
                                              'agent-name agent-name
                                              'full-text text
                                              'summary summary
                                              'timestamp timestamp
                                              'help-echo "View full message in separate buffer")
                          (insert "\n"))))
                    (insert "\n"))
                  ;; Add message-key property to entire message area
                  (put-text-property msg-start-pos (point) 'message-key msg-key))
                (setq msg-index (1+ msg-index)))))
          ;; Show prompt if available
          (when prompt
            (insert prefix "  ")
            (insert (propertize "Prompt" 'face 'agent-shell-claude-agents-tracker-section-label))
            (insert "\n")
            (let ((truncated-prompt (agent-shell-claude-agents-tracker--truncate-output
                                     prompt agent-shell-claude-agents-tracker-output-max-lines)))
              (dolist (line (split-string truncated-prompt "\n"))
                (insert prefix "    ")
                (insert (propertize line 'face 'agent-shell-claude-agents-tracker-output))
                (insert "\n")))
            (insert "\n"))
          ;; Show output if available (with collapsible format like messages)
          (when output
            (insert prefix "  ")
            (insert (propertize "Output" 'face 'agent-shell-claude-agents-tracker-section-label))
            (insert "\n")
            (let* ((output-key (format "%s:output" (or expand-key "unknown")))
                   (output-collapsed (gethash output-key agent-shell-claude-agents-tracker--collapsed-messages))
                   (truncated (agent-shell-claude-agents-tracker--truncate-output
                               output agent-shell-claude-agents-tracker-output-max-lines))
                   (is-truncated (agent-shell-claude-agents-tracker--text-truncated-p
                                  output agent-shell-claude-agents-tracker-output-max-lines))
                   (output-start-pos (point)))
              (insert prefix "    ")
              ;; Collapse/expand button
              (insert-text-button (if output-collapsed "▶" "▼")
                                  'face 'agent-shell-claude-agents-tracker-expand-button
                                  'action (lambda (button)
                                            (agent-shell-claude-agents-tracker-toggle-message
                                             (button-get button 'message-key)))
                                  'message-key output-key
                                  'help-echo "Click to toggle output")
              (insert " ")
              (insert (propertize (or description type "Agent result")
                                  'face 'agent-shell-claude-agents-tracker-meta))
              (insert "\n")
              ;; Only show content if not collapsed
              (unless output-collapsed
                (dolist (line (split-string truncated "\n"))
                  (insert prefix "      ")
                  (insert (propertize line 'face 'agent-shell-claude-agents-tracker-output))
                  (insert "\n"))
                ;; Add "View full" button if truncated
                (when is-truncated
                  (insert prefix "      ")
                  (insert-text-button "📄 View full"
                                      'face 'agent-shell-claude-agents-tracker-expand-button
                                      'action (lambda (button)
                                                (agent-shell-claude-agents-tracker-view-full-message
                                                 (button-get button 'agent-name)
                                                 (button-get button 'full-text)
                                                 (button-get button 'summary)
                                                 (button-get button 'timestamp)))
                                      'agent-name agent-name
                                      'full-text output
                                      'summary (or description type "Agent output")
                                      'timestamp (when completed-at (format-time-string "%H:%M:%S" completed-at))
                                      'help-echo "View full output in separate buffer")
                  (insert "\n")))
              ;; Add message-key property to entire output area (for > and < bindings)
              (put-text-property output-start-pos (point) 'message-key output-key))))
      ;; === COMPACT VIEW: Single line ===
      ;; Format: ▶ ● Type  Description...  2m [3]
      (insert prefix)
      (insert-text-button "▶"
                          'face 'agent-shell-claude-agents-tracker-expand-button
                          'action (lambda (button)
                                    (let ((key (button-get button 'expand-key))
                                          (name (button-get button 'agent-name)))
                                      (agent-shell-claude-agents-tracker-toggle-output key)
                                      (when name
                                        (agent-shell-claude-agents-tracker--mark-messages-read name))))
                          'expand-key expand-key
                          'agent-name agent-name
                          'help-echo "Click to expand")
      (insert " ")
      (insert (propertize status-indicator
                          'face (agent-shell-claude-agents-tracker--status-face status)))
      (insert " ")
      (insert (propertize (or type "Agent") 'face 'agent-shell-claude-agents-tracker-type))
      (insert "  ")
      (when (and compact-desc (not (string-empty-p compact-desc)))
        (insert (propertize compact-desc 'face 'agent-shell-claude-agents-tracker-meta))
        (insert "  "))
      (when (and compact-duration (not (string-empty-p compact-duration)))
        (insert (propertize compact-duration 'face 'agent-shell-claude-agents-tracker-meta)))
      (when has-unread
        (insert " ")
        (insert (propertize (format "[%d]" unread-count)
                            'face 'agent-shell-claude-agents-tracker-unread)))
      (when is-waiting
        (insert " ")
        (insert (propertize "⏳ Waiting for response..." 'face 'agent-shell-claude-agents-tracker-waiting)))
      (insert "\n"))
    ;; Spacing between agents
    (insert "\n")
    ;; Store position for navigation
    (when expand-key
      (put-text-property start-pos (point) 'claude-subagent-id expand-key))
    ;; Store teammate info for the entire agent section (for messaging)
    (when (and team-name member-name)
      (put-text-property start-pos (point) 'claude-teammate-name member-name)
      (put-text-property start-pos (point) 'claude-team-name team-name))))

(defun agent-shell-claude-agents-tracker--find-agent-for-member (member-name)
  "Find a tracked agent matching MEMBER-NAME.
Returns the agent plist or nil if not found."
  (let ((result nil))
    (maphash (lambda (_id agent)
               (when (equal (plist-get agent :name) member-name)
                 (setq result agent)))
             agent-shell-claude-agents-tracker--agents)
    result))

(defun agent-shell-claude-agents-tracker--insert-team-member (member team-name)
  "Insert a team MEMBER from TEAM-NAME into the buffer."
  (let* ((member-name (cdr (assq 'name member)))
         (agent-type (cdr (assq 'agentType member)))
         (agent-id (cdr (assq 'agentId member)))
         ;; Try to find tracked agent data for this member
         (tracked-agent (agent-shell-claude-agents-tracker--find-agent-for-member member-name))
         ;; Build a combined agent plist
         (agent (if tracked-agent
                    ;; Use tracked data but fill in missing fields
                    (let ((copy (copy-sequence tracked-agent)))
                      (unless (plist-get copy :type)
                        (plist-put copy :type agent-type))
                      copy)
                  ;; Create minimal plist from team config
                  (list :name member-name
                        :type agent-type
                        :description (format "%s (%s...)"
                                             (or member-name "unnamed")
                                             (if agent-id
                                                 (substring agent-id 0 (min 8 (length agent-id)))
                                               "?")))))
         ;; Capture position before inserting anything
         (section-start (point)))
    ;; Insert member name as a header
    (insert "  ")
    (insert (propertize (or member-name "unnamed")
                        'face 'agent-shell-claude-agents-tracker-teammate))
    (insert "\n")
    ;; Insert the agent info with team context for messaging
    (agent-shell-claude-agents-tracker--insert-subagent agent t team-name member-name)
    ;; Set teammate properties on entire section (including name header)
    (put-text-property section-start (point) 'claude-teammate-name member-name)
    (put-text-property section-start (point) 'claude-team-name team-name)))

(defun agent-shell-claude-agents-tracker--compute-summary ()
  "Compute summary statistics for the header line.
Returns a plist with :total, :running, :completed, :failed, :unread."
  (let ((total 0)
        (running 0)
        (completed 0)
        (failed 0)
        (unread 0))
    ;; Count agents by status
    (maphash (lambda (_id agent)
               (cl-incf total)
               (pcase (plist-get agent :status)
                 ("running" (cl-incf running))
                 ("completed" (cl-incf completed))
                 ("failed" (cl-incf failed))))
             agent-shell-claude-agents-tracker--agents)
    ;; Count unread messages across all agents
    (maphash (lambda (agent-name _messages)
               (cl-incf unread (agent-shell-claude-agents-tracker--agent-unread-count agent-name)))
             agent-shell-claude-agents-tracker--agent-messages)
    (list :total total :running running :completed completed :failed failed :unread unread)))

(defun agent-shell-claude-agents-tracker--format-summary (stats)
  "Format STATS plist into a summary string.
Omits zero-count segments."
  (let* ((total (plist-get stats :total))
         (running (plist-get stats :running))
         (completed (plist-get stats :completed))
         (failed (plist-get stats :failed))
         (unread (plist-get stats :unread))
         (status-parts nil)
         (agent-word (if (= total 1) "agent" "agents")))
    (when (> total 0)
      ;; Build status breakdown
      (when (> failed 0)
        (push (format "%d failed" failed) status-parts))
      (when (> completed 0)
        (push (format "%d completed" completed) status-parts))
      (when (> running 0)
        (push (format "%d running" running) status-parts))
      ;; Format the main part
      (let ((main-part (if status-parts
                           (format "%d %s: %s" total agent-word
                                   (string-join (nreverse status-parts) ", "))
                         (format "%d %s" total agent-word))))
        ;; Add unread count if > 0
        (if (> unread 0)
            (format "%s | %d unread" main-part unread)
          main-part)))))

(defun agent-shell-claude-agents-tracker--refresh-display ()
  "Refresh the tracker buffer display."
  (when-let ((buf (get-buffer agent-shell-claude-agents-tracker--buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (pos (point)))
        (erase-buffer)
        (insert (propertize "Code Agents\n" 'face 'agent-shell-claude-agents-tracker-header))
        (insert (propertize (make-string 50 ?─) 'face 'agent-shell-claude-agents-tracker-meta))
        (insert "\n")
        ;; Summary line
        (let* ((stats (agent-shell-claude-agents-tracker--compute-summary))
               (summary (agent-shell-claude-agents-tracker--format-summary stats)))
          (when summary
            (insert (propertize summary 'face 'agent-shell-claude-agents-tracker-meta))
            (insert "\n")))
        (insert "\n")
        ;; Collect team member names to exclude from standalone agents
        (let ((team-member-names (make-hash-table :test 'equal))
              (has-content nil))
          ;; First, collect team member names (to exclude from standalone section)
          (maphash (lambda (_name team)
                     (let ((members (plist-get team :members)))
                       (dolist (member members)
                         (let ((member-name (cdr (assq 'name member))))
                           (when member-name
                             (puthash member-name t team-member-names))))))
                   agent-shell-claude-agents-tracker--teams)
          ;; Display standalone agents FIRST
          (let ((ungrouped nil))
            (maphash (lambda (_id agent)
                       (let ((name (plist-get agent :name)))
                         (unless (gethash name team-member-names)
                           (push agent ungrouped))))
                     agent-shell-claude-agents-tracker--agents)
            (when ungrouped
              (setq has-content t)
              (insert (propertize "Standalone Agents"
                                  'face 'agent-shell-claude-agents-tracker-parent))
              (insert "\n")
              (let ((len (length ungrouped)))
                (dotimes (i len)
                  (agent-shell-claude-agents-tracker--insert-subagent
                   (nth i ungrouped) (= i (1- len)))))))
          ;; Then, display teams and their members (below standalone)
          (maphash (lambda (_name team)
                     (let* ((team-name (plist-get team :name))
                            (members (plist-get team :members))
                            ;; Filter out team-lead from display
                            (non-lead-members (seq-filter
                                               (lambda (m)
                                                 (not (equal (cdr (assq 'name m)) "team-lead")))
                                               members)))
                       (when non-lead-members
                         (when has-content
                           (insert "\n"))
                         (setq has-content t)
                         ;; Team header
                         (insert (propertize (format "Team: %s" team-name)
                                             'face 'agent-shell-claude-agents-tracker-parent))
                         (insert "\n")
                         ;; Insert each member
                         (dolist (member non-lead-members)
                           (agent-shell-claude-agents-tracker--insert-team-member member team-name)))))
                   agent-shell-claude-agents-tracker--teams)
          ;; Show placeholder if nothing to display
          (unless has-content
            (insert (propertize "No agents tracked yet.\n\n"
                                'face 'agent-shell-claude-agents-tracker-meta)
                    (propertize "Agents will appear here when Claude Code\n"
                                'face 'agent-shell-claude-agents-tracker-meta)
                    (propertize "uses the Agent tool to spawn them.\n"
                                'face 'agent-shell-claude-agents-tracker-meta))))
        (goto-char (min pos (point-max)))))))

;;; Mode-line

(defun agent-shell-claude-agents-tracker--mode-line-string ()
  "Return mode-line string showing subagent count."
  (when agent-shell-claude-agents-tracker-show-mode-line
    (let* ((agents (hash-table-values agent-shell-claude-agents-tracker--agents))
           (running (seq-count (lambda (a)
                                 (equal (plist-get a :status) "running"))
                               agents))
           (total (length agents)))
      (when (> total 0)
        (propertize (format " [Sub:%d/%d]" running total)
                    'face (if (> running 0)
                              'agent-shell-claude-agents-tracker-running
                            'mode-line))))))

;;; Inbox Polling

(defface agent-shell-claude-agents-tracker-inbox-sender
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for message sender in inbox."
  :group 'agent-shell-claude-agents-tracker)

(defface agent-shell-claude-agents-tracker-inbox-timestamp
  '((t :inherit shadow :slant italic))
  "Face for message timestamp in inbox."
  :group 'agent-shell-claude-agents-tracker)

(defun agent-shell-claude-agents-tracker--find-my-inboxes ()
  "Find all inbox files where I am the team-lead.
Returns list of (team-name . inbox-file-path) pairs."
  (let ((teams-dir (agent-shell-claude-agents-tracker--teams-dir))
        (inboxes nil))
    (when (file-directory-p teams-dir)
      (dolist (team-dir (directory-files teams-dir t "^[^.]"))
        (when (file-directory-p team-dir)
          (let ((inbox-file (expand-file-name "inboxes/team-lead.json" team-dir)))
            (when (file-exists-p inbox-file)
              (push (cons (file-name-nondirectory team-dir) inbox-file)
                    inboxes))))))
    inboxes))

(defun agent-shell-claude-agents-tracker--parse-inbox (inbox-file)
  "Parse INBOX-FILE and return list of messages."
  (when (file-exists-p inbox-file)
    (condition-case err
        (let ((json-object-type 'alist)
              (json-array-type 'list))
          (json-read-file inbox-file))
      (error
       (message "agent-shell-claude-agents-tracker: Error parsing inbox %s: %s" inbox-file err)
       nil))))

(defun agent-shell-claude-agents-tracker--is-idle-notification-p (message)
  "Return non-nil if MESSAGE is an idle notification (not a real message)."
  (let ((text (cdr (assq 'text message))))
    (and text
         (string-match-p "\"type\":\\s-*\"idle_notification\"" text))))

(defun agent-shell-claude-agents-tracker--filter-real-messages (messages)
  "Filter MESSAGES to exclude idle notifications and system messages."
  (seq-filter
   (lambda (msg)
     (not (agent-shell-claude-agents-tracker--is-idle-notification-p msg)))
   messages))

(defun agent-shell-claude-agents-tracker--poll-inboxes ()
  "Poll all team inboxes for new messages and store them per agent."
  (let ((inboxes (agent-shell-claude-agents-tracker--find-my-inboxes))
        (has-new-messages nil))
    (dolist (inbox-entry inboxes)
      (let* ((team-name (car inbox-entry))
             (inbox-file (cdr inbox-entry))
             (all-messages (agent-shell-claude-agents-tracker--parse-inbox inbox-file))
             (messages (agent-shell-claude-agents-tracker--filter-real-messages all-messages))
             (seen-count (or (gethash inbox-file agent-shell-claude-agents-tracker--seen-messages) 0))
             (current-count (length messages)))
        ;; Check if there are new messages
        (when (> current-count seen-count)
          (setq has-new-messages t)
          (let ((new-msgs (nthcdr seen-count messages)))
            (dolist (msg new-msgs)
              (let* ((from (cdr (assq 'from msg)))
                     (msg-plist (list :team team-name
                                      :from from
                                      :text (cdr (assq 'text msg))
                                      :summary (cdr (assq 'summary msg))
                                      :timestamp (cdr (assq 'timestamp msg))
                                      :color (cdr (assq 'color msg))
                                      :read nil))
                     (existing (gethash from agent-shell-claude-agents-tracker--agent-messages)))
                ;; Clear waiting state for this agent
                (remhash from agent-shell-claude-agents-tracker--waiting-for-response)
                ;; Append to agent's message list
                (puthash from (append existing (list msg-plist))
                         agent-shell-claude-agents-tracker--agent-messages)))))
        ;; Update seen count
        (puthash inbox-file current-count agent-shell-claude-agents-tracker--seen-messages)))
    ;; Refresh display and notify if new messages
    (when has-new-messages
      (agent-shell-claude-agents-tracker--refresh-display)
      (message "New message from teammate(s)"))))

(defun agent-shell-claude-agents-tracker--agent-has-unread-p (agent-name)
  "Return non-nil if AGENT-NAME has unread messages."
  (let ((messages (gethash agent-name agent-shell-claude-agents-tracker--agent-messages)))
    (seq-some (lambda (msg) (not (plist-get msg :read))) messages)))

(defun agent-shell-claude-agents-tracker--agent-unread-count (agent-name)
  "Return count of unread messages from AGENT-NAME."
  (let ((messages (gethash agent-name agent-shell-claude-agents-tracker--agent-messages)))
    (seq-count (lambda (msg) (not (plist-get msg :read))) messages)))

(defun agent-shell-claude-agents-tracker--mark-messages-read (agent-name)
  "Mark all messages from AGENT-NAME as read."
  (let ((messages (gethash agent-name agent-shell-claude-agents-tracker--agent-messages)))
    (dolist (msg messages)
      (plist-put msg :read t))
    (puthash agent-name messages agent-shell-claude-agents-tracker--agent-messages)))

(defun agent-shell-claude-agents-tracker--start-inbox-timer ()
  "Start the inbox polling timer."
  (agent-shell-claude-agents-tracker--stop-inbox-timer)
  (setq agent-shell-claude-agents-tracker--inbox-timer
        (run-with-timer agent-shell-claude-agents-tracker-inbox-poll-interval
                        agent-shell-claude-agents-tracker-inbox-poll-interval
                        #'agent-shell-claude-agents-tracker--poll-inboxes)))

(defun agent-shell-claude-agents-tracker--stop-inbox-timer ()
  "Stop the inbox polling timer."
  (when agent-shell-claude-agents-tracker--inbox-timer
    (cancel-timer agent-shell-claude-agents-tracker--inbox-timer)
    (setq agent-shell-claude-agents-tracker--inbox-timer nil)))

(defun agent-shell-claude-agents-tracker-clear-inbox ()
  "Clear all messages and reset message tracking."
  (interactive)
  (when (yes-or-no-p "Clear all messages and reset tracking? ")
    (clrhash agent-shell-claude-agents-tracker--seen-messages)
    (clrhash agent-shell-claude-agents-tracker--agent-messages)
    (agent-shell-claude-agents-tracker--refresh-display)
    (message "Messages cleared")))

(defun agent-shell-claude-agents-tracker-poll-inbox-now ()
  "Manually poll inboxes for new messages."
  (interactive)
  (agent-shell-claude-agents-tracker--poll-inboxes)
  (message "Inbox poll complete"))

;;; Full Message Viewer

(defvar agent-shell-claude-agents-tracker-message-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'agent-shell-claude-agents-tracker-message-quit)
    map)
  "Keymap for `agent-shell-claude-agents-tracker-message-minor-mode'.")

(define-minor-mode agent-shell-claude-agents-tracker-message-minor-mode
  "Minor mode for Claude message viewer buffer.
Provides `q' to quit and return to the tracker."
  :lighter " Claude-Msg"
  :keymap agent-shell-claude-agents-tracker-message-minor-mode-map
  (when agent-shell-claude-agents-tracker-message-minor-mode
    ;; Set up evil binding when mode is enabled
    (when (bound-and-true-p evil-mode)
      (evil-local-set-key 'normal (kbd "q") #'agent-shell-claude-agents-tracker-message-quit))))

(defun agent-shell-claude-agents-tracker-message-quit ()
  "Close the message buffer and restore the previous window configuration."
  (interactive)
  (let ((msg-buf (current-buffer))
        (win-config agent-shell-claude-agents-tracker--saved-window-config)
        (pos agent-shell-claude-agents-tracker--return-position))
    ;; Restore window configuration
    (when win-config
      (set-window-configuration win-config))
    ;; Kill the message buffer
    (when (buffer-live-p msg-buf)
      (kill-buffer msg-buf))
    ;; Restore cursor position in tracker
    (when pos
      (goto-char (min pos (point-max))))))

(defun agent-shell-claude-agents-tracker-view-full-message (agent-name text &optional summary timestamp)
  "Display full TEXT from AGENT-NAME in a dedicated buffer.
SUMMARY and TIMESTAMP are optional metadata to display.
Uses `markdown-view-mode' or `gfm-view-mode' for rendering."
  ;; Save window configuration and cursor position before opening
  (setq agent-shell-claude-agents-tracker--saved-window-config (current-window-configuration))
  (setq agent-shell-claude-agents-tracker--return-position (point))
  (let ((buf (get-buffer-create agent-shell-claude-agents-tracker--message-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; Insert metadata as markdown
        (insert (format "# Message from: %s\n\n" (or agent-name "unknown")))
        (when (or timestamp summary)
          (when timestamp
            (insert (format "**Time:** %s  \n" timestamp)))
          (when summary
            (insert (format "**Summary:** %s\n" summary)))
          (insert "\n---\n\n"))
        (insert text)
        (insert "\n"))
      ;; Use markdown-view-mode or gfm-view-mode for read-only markdown
      (cond
       ((fboundp 'gfm-view-mode)
        (gfm-view-mode))
       ((fboundp 'markdown-view-mode)
        (markdown-view-mode))
       ((fboundp 'gfm-mode)
        (gfm-mode)
        (setq-local buffer-read-only t))
       ((fboundp 'markdown-mode)
        (markdown-mode)
        (setq-local buffer-read-only t))
       (t
        (special-mode)))
      ;; Enable minor mode for q binding (works on top of any major mode)
      (agent-shell-claude-agents-tracker-message-minor-mode 1)
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun agent-shell-claude-agents-tracker--text-truncated-p (text max-lines)
  "Return non-nil if TEXT exceeds MAX-LINES."
  (when text
    (> (length (split-string text "\n")) max-lines)))

;;; Interactive Commands

;;;###autoload
(defun agent-shell-claude-agents-tracker-show ()
  "Display the subagent tracker buffer."
  (interactive)
  (let ((buf (get-buffer-create agent-shell-claude-agents-tracker--buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'agent-shell-claude-agents-tracker-sidebar-mode)
        (agent-shell-claude-agents-tracker-sidebar-mode))
      ;; Load teams and refresh
      (agent-shell-claude-agents-tracker--reload-teams)
      (agent-shell-claude-agents-tracker--refresh-display))
    ;; Use switch-to-buffer-other-window to bypass display-buffer-alist rules
    (switch-to-buffer-other-window buf)))

;;;###autoload
(defun agent-shell-claude-agents-tracker-hide ()
  "Hide the subagent tracker sidebar."
  (interactive)
  (when-let ((buf (get-buffer agent-shell-claude-agents-tracker--buffer-name)))
    (when-let ((win (get-buffer-window buf t)))
      (delete-window win))))

;;;###autoload
(defun agent-shell-claude-agents-tracker-toggle ()
  "Toggle the subagent tracker sidebar."
  (interactive)
  (if-let ((buf (get-buffer agent-shell-claude-agents-tracker--buffer-name)))
      (if (get-buffer-window buf t)
          (agent-shell-claude-agents-tracker-hide)
        (agent-shell-claude-agents-tracker-show))
    (agent-shell-claude-agents-tracker-show)))

(defun agent-shell-claude-agents-tracker-refresh ()
  "Manually refresh the tracker display."
  (interactive)
  ;; Also reload team configs in case file watcher missed them
  (agent-shell-claude-agents-tracker--reload-teams)
  (agent-shell-claude-agents-tracker--refresh-display))

(defun agent-shell-claude-agents-tracker--reload-teams ()
  "Reload all team configs from ~/.claude/teams/.
Removes teams that no longer exist and adds/updates existing ones."
  (let ((teams-dir (agent-shell-claude-agents-tracker--teams-dir))
        (existing-teams (make-hash-table :test 'equal)))
    ;; First, collect all existing team directories
    (when (file-directory-p teams-dir)
      (dolist (dir (directory-files teams-dir t "^[^.]"))
        (when (file-directory-p dir)
          (let* ((team-name (file-name-nondirectory dir))
                 (config (expand-file-name "config.json" dir)))
            (if (file-exists-p config)
                (progn
                  (puthash team-name t existing-teams)
                  (agent-shell-claude-agents-tracker--parse-team-config config))
              ;; Config doesn't exist, mark for removal
              (remhash team-name agent-shell-claude-agents-tracker--teams))))))
    ;; Remove teams that no longer have directories
    (let ((to-remove nil))
      (maphash (lambda (name _)
                 (unless (gethash name existing-teams)
                   (push name to-remove)))
               agent-shell-claude-agents-tracker--teams)
      (dolist (name to-remove)
        (remhash name agent-shell-claude-agents-tracker--teams)))))

(defun agent-shell-claude-agents-tracker-clear ()
  "Clear all tracked subagents, teams, and messages."
  (interactive)
  (when (yes-or-no-p "Clear all tracked subagents, teams, and messages? ")
    (clrhash agent-shell-claude-agents-tracker--agents)
    (clrhash agent-shell-claude-agents-tracker--expanded-agents)
    (clrhash agent-shell-claude-agents-tracker--teams)
    (clrhash agent-shell-claude-agents-tracker--seen-messages)
    (clrhash agent-shell-claude-agents-tracker--agent-messages)
    (clrhash agent-shell-claude-agents-tracker--expanded-messages)
    (agent-shell-claude-agents-tracker--refresh-display)
    (message "Subagent tracker cleared")))

(defun agent-shell-claude-agents-tracker--safe-claude-subdir-p (path)
  "Return non-nil if PATH is safely under ~/.claude/ directory.
This prevents accidental deletion of files outside the expected location.
Uses `file-truename' to resolve symlinks before checking."
  (let ((claude-dir (expand-file-name "~/.claude/"))
        (expanded-path (file-truename (expand-file-name path))))
    ;; Defense in depth: string-prefix-p handles most traversal cases,
    ;; but we explicitly reject paths containing ".." as an extra safeguard
    (and (string-prefix-p claude-dir expanded-path)
         (not (string-match-p "\\.\\." expanded-path)))))

(defun agent-shell-claude-agents-tracker-reset-all ()
  "Reset everything: clear all state and delete team/task directories.
This will:
1. Clear all internal hash tables (agents, teams, messages)
2. Properly unsubscribe from all agent-shell buffers
3. Stop any running timers
4. Delete all team directories from ~/.claude/teams/
5. Delete all task directories from ~/.claude/tasks/
6. Refresh the display

WARNING: This is destructive and cannot be undone!"
  (interactive)
  (let* ((teams-dir (agent-shell-claude-agents-tracker--teams-dir))
         (tasks-dir (agent-shell-claude-agents-tracker--tasks-dir))
         ;; Count items before confirmation so user sees what will be deleted
         (team-count (if (file-directory-p teams-dir)
                         (length (directory-files teams-dir nil "^[^.]"))
                       0))
         (task-count (if (file-directory-p tasks-dir)
                         (length (directory-files tasks-dir nil "^[^.]"))
                       0))
         (agent-count (hash-table-count agent-shell-claude-agents-tracker--agents))
         (deleted-teams 0)
         (deleted-tasks 0))
    (when (yes-or-no-p
           (format "DANGER: Delete %d team(s), %d task folder(s), %d tracked agent(s)? "
                   team-count task-count agent-count))
      ;; 1. Validate paths are under ~/.claude/ before proceeding
      (unless (and (agent-shell-claude-agents-tracker--safe-claude-subdir-p teams-dir)
                   (agent-shell-claude-agents-tracker--safe-claude-subdir-p tasks-dir))
        (user-error "Safety check failed: paths not under ~/.claude/"))
      ;; 2. Clear all internal hash tables
      (clrhash agent-shell-claude-agents-tracker--agents)
      (clrhash agent-shell-claude-agents-tracker--expanded-agents)
      (clrhash agent-shell-claude-agents-tracker--teams)
      (clrhash agent-shell-claude-agents-tracker--seen-messages)
      (clrhash agent-shell-claude-agents-tracker--agent-messages)
      (clrhash agent-shell-claude-agents-tracker--expanded-messages)
      (clrhash agent-shell-claude-agents-tracker--collapsed-messages)
      (clrhash agent-shell-claude-agents-tracker--waiting-for-response)
      ;; 3. Properly unsubscribe from all buffers
      ;; We iterate over a copy-free list since unsubscribe modifies --subscriptions
      ;; by removing entries, but dolist captures the list head before iteration
      (dolist (entry agent-shell-claude-agents-tracker--subscriptions)
        (agent-shell-claude-agents-tracker--unsubscribe-from-buffer (car entry)))
      (setq agent-shell-claude-agents-tracker--subscriptions nil)
      ;; 4. Stop all timers
      (agent-shell-claude-agents-tracker--stop-refresh-timer)
      (agent-shell-claude-agents-tracker--stop-inbox-timer)
      ;; 5. Delete team directories (with path validation for each)
      (when (file-directory-p teams-dir)
        (dolist (dir (directory-files teams-dir t "^[^.]"))
          (when (and (file-directory-p dir)
                     (agent-shell-claude-agents-tracker--safe-claude-subdir-p dir))
            (condition-case err
                (progn
                  (delete-directory dir t)
                  (setq deleted-teams (1+ deleted-teams)))
              (error
               (message "Failed to delete team dir %s: %s" dir err))))))
      ;; 6. Delete task directories (with path validation for each)
      (when (file-directory-p tasks-dir)
        (dolist (dir (directory-files tasks-dir t "^[^.]"))
          (when (and (file-directory-p dir)
                     (agent-shell-claude-agents-tracker--safe-claude-subdir-p dir))
            (condition-case err
                (progn
                  (delete-directory dir t)
                  (setq deleted-tasks (1+ deleted-tasks)))
              (error
               (message "Failed to delete task dir %s: %s" dir err))))))
      ;; 7. Refresh display
      (agent-shell-claude-agents-tracker--refresh-display)
      (message "Reset complete: deleted %d team(s) and %d task folder(s)"
               deleted-teams deleted-tasks))))

(defun agent-shell-claude-agents-tracker-toggle-output (tool-call-id)
  "Toggle the expanded state of output for TOOL-CALL-ID."
  (interactive (list (get-text-property (point) 'claude-subagent-id)))
  (when tool-call-id
    (if (gethash tool-call-id agent-shell-claude-agents-tracker--expanded-agents)
        (remhash tool-call-id agent-shell-claude-agents-tracker--expanded-agents)
      (puthash tool-call-id t agent-shell-claude-agents-tracker--expanded-agents))
    (agent-shell-claude-agents-tracker--refresh-display)))

(defun agent-shell-claude-agents-tracker-toggle-message (message-key)
  "Toggle the collapsed state of message MESSAGE-KEY."
  (interactive (list (get-text-property (point) 'message-key)))
  (when message-key
    (if (gethash message-key agent-shell-claude-agents-tracker--collapsed-messages)
        (remhash message-key agent-shell-claude-agents-tracker--collapsed-messages)
      (puthash message-key t agent-shell-claude-agents-tracker--collapsed-messages))
    (agent-shell-claude-agents-tracker--refresh-display)))

(defun agent-shell-claude-agents-tracker-toggle-at-point ()
  "Toggle expansion at point. Prefers message toggle over agent toggle."
  (interactive)
  (let ((msg-key (get-text-property (point) 'message-key))
        (agent-id (get-text-property (point) 'claude-subagent-id)))
    (cond
     (msg-key
      (agent-shell-claude-agents-tracker-toggle-message msg-key))
     (agent-id
      (agent-shell-claude-agents-tracker-toggle-output agent-id))
     (t
      (message "No subagent or message at point")))))

(defun agent-shell-claude-agents-tracker-expand-message-at-point ()
  "Expand the message at point (if collapsed)."
  (interactive)
  (let ((msg-key (get-text-property (point) 'message-key)))
    (if msg-key
        (progn
          (remhash msg-key agent-shell-claude-agents-tracker--collapsed-messages)
          (agent-shell-claude-agents-tracker--refresh-display))
      (message "No message at point"))))

(defun agent-shell-claude-agents-tracker-collapse-message-at-point ()
  "Collapse the message at point (if expanded)."
  (interactive)
  (let ((msg-key (get-text-property (point) 'message-key)))
    (if msg-key
        (progn
          (puthash msg-key t agent-shell-claude-agents-tracker--collapsed-messages)
          (agent-shell-claude-agents-tracker--refresh-display))
      (message "No message at point"))))

(defun agent-shell-claude-agents-tracker-expand-all ()
  "Expand output for all subagents."
  (interactive)
  (maphash (lambda (id _agent)
             (puthash id t agent-shell-claude-agents-tracker--expanded-agents))
           agent-shell-claude-agents-tracker--agents)
  (agent-shell-claude-agents-tracker--refresh-display))

(defun agent-shell-claude-agents-tracker-collapse-all ()
  "Collapse output for all subagents."
  (interactive)
  (clrhash agent-shell-claude-agents-tracker--expanded-agents)
  (agent-shell-claude-agents-tracker--refresh-display))

(defun agent-shell-claude-agents-tracker-message-teammate (teammate-name team-name)
  "Send a message to TEAMMATE-NAME in TEAM-NAME.
Sends the message request directly to the parent agent-shell session."
  (interactive
   (let ((name (get-text-property (point) 'claude-teammate-name))
         (team (get-text-property (point) 'claude-team-name)))
     (if name
         (list name team)
       (user-error "No teammate at point"))))
  (let ((msg-text (read-string (format "Message to %s: " teammate-name))))
    (when (and msg-text (not (string-empty-p msg-text)))
      (let ((shell-buf (agent-shell-claude-agents-tracker--find-agent-shell-buffer)))
        (if shell-buf
            (let ((input (format "Send message to teammate \"%s\": %s"
                                 teammate-name msg-text)))
              ;; Set waiting state
              (puthash teammate-name (current-time) agent-shell-claude-agents-tracker--waiting-for-response)
              ;; Call from within the buffer context so it can access session state
              (with-current-buffer shell-buf
                (agent-shell--send-command :prompt input :shell-buffer shell-buf))
              (agent-shell-claude-agents-tracker--refresh-display)
              (message "Message sent to %s" teammate-name))
          (user-error "No agent-shell buffer found"))))))

(defun agent-shell-claude-agents-tracker-message-at-point ()
  "Send a message to the teammate at point."
  (interactive)
  (let ((name (get-text-property (point) 'claude-teammate-name))
        (team (get-text-property (point) 'claude-team-name)))
    (if name
        (agent-shell-claude-agents-tracker-message-teammate name team)
      (message "No teammate at point"))))

;;;###autoload
(defun agent-shell-claude-agents-tracker-send-message ()
  "Interactively select a team and teammate, then send a message.
Prompts for team name, then teammate, then message content."
  (interactive)
  ;; Ensure teams are loaded
  (agent-shell-claude-agents-tracker--reload-teams)
  (if (zerop (hash-table-count agent-shell-claude-agents-tracker--teams))
      (user-error "No teams found. Create a team first with TeamCreate")
    ;; Get list of team names
    (let* ((team-names (hash-table-keys agent-shell-claude-agents-tracker--teams))
           (team-name (if (= 1 (length team-names))
                          (car team-names)
                        (completing-read "Select team: " team-names nil t)))
           (team (gethash team-name agent-shell-claude-agents-tracker--teams))
           (members (plist-get team :members))
           (member-names (mapcar (lambda (m) (cdr (assq 'name m))) members)))
      (if (null member-names)
          (user-error "Team %s has no members" team-name)
        (let* ((teammate-name (completing-read
                               (format "Send message to [%s]: " team-name)
                               member-names nil t))
               (msg-text (read-string (format "Message to %s: " teammate-name))))
          (when (and msg-text (not (string-empty-p msg-text)))
            (let ((shell-buf (agent-shell-claude-agents-tracker--find-agent-shell-buffer)))
              (if shell-buf
                  (let ((input (format "Send message to teammate \"%s\": %s"
                                       teammate-name msg-text)))
                    ;; Set waiting state
                    (puthash teammate-name (current-time) agent-shell-claude-agents-tracker--waiting-for-response)
                    ;; Call from within the buffer context so it can access session state
                    (with-current-buffer shell-buf
                      (agent-shell--send-command :prompt input :shell-buffer shell-buf))
                    (agent-shell-claude-agents-tracker--refresh-display)
                    (message "Message sent to %s" teammate-name))
                (user-error "No agent-shell buffer found")))))))))

(defun agent-shell-claude-agents-tracker--find-agent-shell-buffer ()
  "Find an active agent-shell buffer to use for messaging."
  ;; First try buffers that spawned tracked agents
  (let ((parent-bufs (make-hash-table :test 'equal)))
    (maphash (lambda (_id agent)
               (let ((buf (plist-get agent :parent-buffer)))
                 (when (buffer-live-p buf)
                   (puthash buf t parent-bufs))))
             agent-shell-claude-agents-tracker--agents)
    ;; Return first live parent buffer
    (catch 'found
      (maphash (lambda (buf _)
                 (when (buffer-live-p buf)
                   (throw 'found buf)))
               parent-bufs)
      ;; Fallback: find any agent-shell buffer
      (seq-find (lambda (buf)
                  (with-current-buffer buf
                    (derived-mode-p 'agent-shell-mode)))
                (buffer-list)))))

;;; Sidebar Mode

(defvar agent-shell-claude-agents-tracker-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'agent-shell-claude-agents-tracker-refresh)
    (define-key map "q" #'agent-shell-claude-agents-tracker-hide)
    (define-key map "c" #'agent-shell-claude-agents-tracker-clear)
    (define-key map "R" #'agent-shell-claude-agents-tracker-reset-all)
    (define-key map "m" #'agent-shell-claude-agents-tracker-message-at-point)
    (define-key map (kbd "TAB") #'agent-shell-claude-agents-tracker-toggle-at-point)
    (define-key map (kbd "RET") #'agent-shell-claude-agents-tracker-toggle-at-point)
    (define-key map ">" #'agent-shell-claude-agents-tracker-expand-message-at-point)
    (define-key map "<" #'agent-shell-claude-agents-tracker-collapse-message-at-point)
    (define-key map "e" #'agent-shell-claude-agents-tracker-expand-all)
    (define-key map "E" #'agent-shell-claude-agents-tracker-collapse-all)
    (define-key map "i" #'agent-shell-claude-agents-tracker-poll-inbox-now)
    (define-key map "I" #'agent-shell-claude-agents-tracker-clear-inbox)
    map)
  "Keymap for `agent-shell-claude-agents-tracker-sidebar-mode'.")

;; Evil keybindings - defined at load time for the mode map
(with-eval-after-load 'evil
  (evil-define-key* 'normal agent-shell-claude-agents-tracker-sidebar-mode-map
    "g" #'agent-shell-claude-agents-tracker-refresh
    "q" #'agent-shell-claude-agents-tracker-hide
    "c" #'agent-shell-claude-agents-tracker-clear
    "R" #'agent-shell-claude-agents-tracker-reset-all
    "m" #'agent-shell-claude-agents-tracker-message-at-point
    (kbd "TAB") #'agent-shell-claude-agents-tracker-toggle-at-point
    (kbd "RET") #'agent-shell-claude-agents-tracker-toggle-at-point
    ">" #'agent-shell-claude-agents-tracker-expand-message-at-point
    "<" #'agent-shell-claude-agents-tracker-collapse-message-at-point
    "e" #'agent-shell-claude-agents-tracker-expand-all
    "E" #'agent-shell-claude-agents-tracker-collapse-all
    "i" #'agent-shell-claude-agents-tracker-poll-inbox-now
    "I" #'agent-shell-claude-agents-tracker-clear-inbox)
  (evil-define-key* 'motion agent-shell-claude-agents-tracker-sidebar-mode-map
    "g" #'agent-shell-claude-agents-tracker-refresh
    "q" #'agent-shell-claude-agents-tracker-hide
    "c" #'agent-shell-claude-agents-tracker-clear
    "R" #'agent-shell-claude-agents-tracker-reset-all
    "m" #'agent-shell-claude-agents-tracker-message-at-point
    (kbd "TAB") #'agent-shell-claude-agents-tracker-toggle-at-point
    (kbd "RET") #'agent-shell-claude-agents-tracker-toggle-at-point
    ">" #'agent-shell-claude-agents-tracker-expand-message-at-point
    "<" #'agent-shell-claude-agents-tracker-collapse-message-at-point
    "e" #'agent-shell-claude-agents-tracker-expand-all
    "E" #'agent-shell-claude-agents-tracker-collapse-all
    "i" #'agent-shell-claude-agents-tracker-poll-inbox-now
    "I" #'agent-shell-claude-agents-tracker-clear-inbox))

(define-derived-mode agent-shell-claude-agents-tracker-sidebar-mode special-mode "Code Agents"
  "Major mode for the agent tracker buffer."
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (agent-shell-claude-agents-tracker--refresh-display)))
  (setq buffer-read-only t)
  ;; Enable word wrapping
  (setq truncate-lines nil)
  (setq word-wrap t)
  (visual-line-mode 1))

;;; Global Minor Mode

(defun agent-shell-claude-agents-tracker--start-refresh-timer ()
  "Start the auto-refresh timer."
  (agent-shell-claude-agents-tracker--stop-refresh-timer)
  (setq agent-shell-claude-agents-tracker--refresh-timer
        (run-with-timer agent-shell-claude-agents-tracker-refresh-interval
                        agent-shell-claude-agents-tracker-refresh-interval
                        #'agent-shell-claude-agents-tracker--refresh-display)))

(defun agent-shell-claude-agents-tracker--stop-refresh-timer ()
  "Stop the auto-refresh timer."
  (when agent-shell-claude-agents-tracker--refresh-timer
    (cancel-timer agent-shell-claude-agents-tracker--refresh-timer)
    (setq agent-shell-claude-agents-tracker--refresh-timer nil)))

(defun agent-shell-claude-agents-tracker--setup ()
  "Set up the tracker."
  ;; Subscribe to existing agent-shell buffers
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'agent-shell-mode)
        (agent-shell-claude-agents-tracker--subscribe-to-buffer buf))))
  ;; Hook into new buffer creation
  (add-hook 'agent-shell-mode-hook #'agent-shell-claude-agents-tracker--on-buffer-created)
  ;; Start file watchers
  (agent-shell-claude-agents-tracker--start-file-watchers)
  ;; Start refresh timer
  (agent-shell-claude-agents-tracker--start-refresh-timer)
  ;; Start inbox polling timer
  (agent-shell-claude-agents-tracker--start-inbox-timer)
  ;; Add mode-line indicator
  (when agent-shell-claude-agents-tracker-show-mode-line
    (add-to-list 'global-mode-string '(:eval (agent-shell-claude-agents-tracker--mode-line-string)) t)))

(defun agent-shell-claude-agents-tracker--teardown ()
  "Tear down the tracker."
  ;; Remove subscriptions
  (dolist (entry agent-shell-claude-agents-tracker--subscriptions)
    (agent-shell-claude-agents-tracker--unsubscribe-from-buffer (car entry)))
  (setq agent-shell-claude-agents-tracker--subscriptions nil)
  ;; Remove hook
  (remove-hook 'agent-shell-mode-hook #'agent-shell-claude-agents-tracker--on-buffer-created)
  ;; Stop file watchers
  (agent-shell-claude-agents-tracker--stop-file-watchers)
  ;; Stop refresh timer
  (agent-shell-claude-agents-tracker--stop-refresh-timer)
  ;; Stop inbox polling timer
  (agent-shell-claude-agents-tracker--stop-inbox-timer)
  ;; Remove mode-line indicator
  (setq global-mode-string
        (delete '(:eval (agent-shell-claude-agents-tracker--mode-line-string))
                global-mode-string)))

;;;###autoload
(define-minor-mode agent-shell-claude-agents-tracker-mode
  "Global minor mode to track Claude Code subagents."
  :global t
  :lighter " SubTrack"
  :group 'agent-shell-claude-agents-tracker
  (if agent-shell-claude-agents-tracker-mode
      (agent-shell-claude-agents-tracker--setup)
    (agent-shell-claude-agents-tracker--teardown)))

(provide 'agent-shell-claude-agents-tracker)

;;; agent-shell-claude-agents-tracker.el ends here
