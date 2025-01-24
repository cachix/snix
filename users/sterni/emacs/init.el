;; set up package infrastructure

(require 'use-package)
(package-initialize)

;; By default, Emacs only uses the default font for ASCII and then falls back to
;; fontset-default which uses random fonts (the documentation describes this
;; accurately). Emacs would be better off if it used the fallback order defined
;; by fontconfig instead of implementing its own scheme for this…
;; In any case, I've found that after setting the default font via methods like
;; (add-to-list 'default-frame-alist …), (set-face-attribute 'default …) etc.
;; it is impossible to change the fontset this font becomes part of (for ascii).
;; Specifically, the following snippet from the Emacs manual just does not seem
;; to work (https://www.gnu.org/software/emacs/manual/html_node/emacs/Modifying-Fontsets.html):
;;
;;     (set-fontset-font "fontset-startup" nil "DejaVu Sans Mono"
;;                       nil 'append)
;;
;; This may very well be my ignorace, but I've found that just setting the ascii
;; and unicode charsets of fontset-startup to a generic Monospace-11 (remember
;; if we use set-face-attribute to change the font height, everything breaks!)
;; works fine.
(let ((font "Monospace-11"))
  (set-fontset-font "fontset-startup" 'ascii font)
  (set-fontset-font "fontset-startup" 'unicode font))

(setq inhibit-startup-message t
      display-time-24hr-format t
      select-enable-clipboard t)

;; Reload files
(global-auto-revert-mode 1)

;; Indent
(setq-default indent-tabs-mode nil)
(setq tab-width 2
      css-indent-offset tab-width)

;; UTF-8
(setq locale-coding-system 'utf-8)
(set-terminal-coding-system 'utf-8)
(set-keyboard-coding-system 'utf-8)
(set-selection-coding-system 'utf-8)
(prefer-coding-system 'utf-8)

;; Disable unnecessary GUI elements
(scroll-bar-mode 0)
(menu-bar-mode 0)
(tool-bar-mode 0)

(add-hook 'after-make-frame-functions
          (lambda (frame) (scroll-bar-mode 0)))

;; don't center on cursor when scrolling
(setq scroll-conservatively 1)

;; type less
(defalias 'yes-or-no-p 'y-or-n-p)

;; Extra settings when graphical session
(when window-system
  (setq frame-title-format '(buffer-file-name "%f" ("%b")))
  (mouse-wheel-mode t)
  (blink-cursor-mode -1))

;; /tmp is a tmpfs, but we may want to recover from power loss
(custom-set-variables
 `(temporary-file-directory ,(concat (getenv "HOME") "/.emacs/tmp")))

(setq auto-save-file-name-transforms
      `((".*" ,temporary-file-directory t)))
(setq backup-directory-alist
      `((".*" . ,temporary-file-directory)))
(setq undo-tree-history-directory-alist
      `((".*" . ,temporary-file-directory)))
(setq backup-by-copying t)
(setq create-lockfiles nil)

;; save history
(savehist-mode)
(setq savehist-additional-variables '(search-ring regexp-search-ring magit-cl-history))

;; buffers

;; performance migitations
(global-so-long-mode)

;; unique component should come first for better completion
(setq uniquify-buffer-name-style 'forward)

;; completions
(ido-mode 1)
(setq ido-enable-flex-matching t)
(ido-everywhere)
(fido-mode)

;; Display column numbers
(column-number-mode t)
(setq-default fill-column 80)
(setq display-fill-column-indicator-column t)
(add-hook 'prog-mode-hook #'display-fill-column-indicator-mode)

;; whitespace
(setq whitespace-style '(face trailing tabs)
      whitespace-line-column fill-column)
(add-hook 'prog-mode-hook #'whitespace-mode)
(setq-default indicate-empty-lines t)
(setq-default indicate-buffer-boundaries 'left)
(setq sentence-end-double-space nil)

;;; Configure built in modes

;; Perl
(setq perl-indent-level 2)
(setq perl-continued-statement-offset 0)
(setq perl-continued-brace-offset 0)

;; org mode

(setq org-clock-persist 'history)
(org-clock-persistence-insinuate)

(let* ((org-folder (concat (getenv "HOME") "/files/sync/org"))
       (org-archive-file (concat org-folder "/archive.org")))
  (setq org-archive-location (concat org-archive-file "::")
        org-agenda-files (remove org-archive-file
                                 (directory-files-recursively org-folder "\\.org$"))
        org-default-notes-file (concat org-folder "/context.org")
        initial-buffer-choice org-default-notes-file
        org-refile-targets '((org-agenda-files . (:maxlevel . 4)))))

;; latex

(defun latex-word-count ()
  "Calls texcount on the file the current buffer points to and displays the result."
  (interactive)
  (save-buffer)
  (let* ((file (buffer-file-name)) ; needs to happen outside with-current-buffer
         (word-count
             (with-output-to-string
               (with-current-buffer standard-output
                 (call-process "texcount" nil t nil "-brief" "-utf8" file)))))
      (message (string-trim-right word-count))))

;; ediff
;; doesn't create new window for ediff controls which I always open accidentally
(setq ediff-window-setup-function 'ediff-setup-windows-plain)

;; man
(setq Man-notify-method 'pushy) ; display man page in current window

;; shell

; default, but allows ';' as prompt
(setq shell-prompt-pattern "^[^#$%>;\n]*[#$%>;] *")

;; projects (see also evil config)

(defun project-magit ()
  "Run magit in the current project dir"
  (interactive)
  (magit (project-root (project-current t))))

(define-key project-prefix-map (kbd "G") 'project-magit)

(setq project-switch-commands
      '((project-find-file "Find file")
        (project-find-regexp "Find regexp")
        (project-dired "Dired")
        (project-shell "Shell")
        (project-magit "Magit")))

;;; Configure packages
(use-package undo-tree
  :config
  (global-undo-tree-mode)
  (setq undo-tree-auto-save-history t))

(use-package magit
  :after evil
  :config
  ; reset (buffer-local) fill-column value to emacs' default
  ; gerrit doesn't like 80 column commit messages…
  (add-hook 'git-commit-mode-hook (lambda () (setq fill-column 72)))
  (evil-define-key 'normal 'global (kbd "<leader>gr") 'magit-status))
(use-package tvl
  :after magit
  :custom tvl-depot-path (concat (getenv "HOME") "/src/depot"))

(setq ediff-split-window-function 'split-window-horizontally)

(use-package evil
  :init
  (setq evil-want-integration t)
  (setq evil-want-keybinding nil)
  (setq evil-shift-width 2)
  (setq evil-split-window-below t)
  (setq evil-split-window-right t)
  (setq evil-undo-system 'undo-tree)
  :config
  (evil-mode 1)
  (evil-set-leader 'normal ",") ;; TODO(sterni): space would be nice, but…
  (evil-set-leader 'visual ",")
  ;; buffer management
  (evil-define-key 'normal 'global (kbd "<leader>bk") 'kill-buffer)
  (evil-define-key 'normal 'global (kbd "<leader>bb") 'switch-to-buffer)
  (evil-define-key 'normal 'global (kbd "<leader>bo") 'switch-to-buffer-other-window)
  (evil-define-key 'normal 'global (kbd "<leader>bl") 'list-buffers)
  (evil-define-key 'normal 'global (kbd "<leader>br") 'revert-buffer)
  ;; window management: C-w hjkl is annoying in neo
  (define-key evil-window-map (kbd "<left>") 'evil-window-left)
  (define-key evil-window-map (kbd "<right>") 'evil-window-right)
  (define-key evil-window-map (kbd "<up>") 'evil-window-up)
  (define-key evil-window-map (kbd "<down>") 'evil-window-down)
  ;; projects
  (evil-define-key 'normal 'global (kbd "<leader>pf") 'project-find-file)
  (evil-define-key 'normal 'global (kbd "<leader>pg") 'project-find-regexp)
  (evil-define-key 'normal 'global (kbd "<leader>pd") 'project-dired)
  (evil-define-key 'normal 'global (kbd "<leader>ps") 'project-shell)
  (evil-define-key 'normal 'global (kbd "<leader>pR") 'project-query-replace-regexp)
  (evil-define-key 'normal 'global (kbd "<leader>pK") 'project-kill-buffers)
  (evil-define-key 'normal 'global (kbd "<leader>pp") 'project-switch-project)
  ;; emacs
  (evil-define-key 'visual 'global (kbd "<leader>ee") 'eval-region)
  (evil-define-key 'normal 'global (kbd "<leader>ee") 'eval-last-sexp)
  (evil-define-key 'normal 'global (kbd "<leader>ep") 'eval-print-last-sexp)
  (evil-define-key 'normal 'global (kbd "<leader>eh") 'help)
  (evil-define-key 'normal 'global (kbd "<leader>em") 'man)
  (evil-define-key '(normal visual) 'global (kbd "<leader>eu") 'browse-url-at-point)
  (evil-define-key '(normal visual) 'global (kbd "<leader>ef") 'ffap)
  ;; modify what is displayed
  (evil-define-key 'normal 'global (kbd "<leader>dw")
    (lambda ()
      (interactive)
      (whitespace-mode 'toggle)
      (display-fill-column-indicator-mode 'toggle)))
  ;; org-mode
  (evil-define-key 'normal 'global (kbd "<leader>oa") 'org-agenda)
  (evil-define-key 'normal 'global (kbd "<leader>oc") 'org-capture)
  (evil-define-key 'normal 'org-mode-map (kbd "<leader>or") 'org-refile)
  (evil-define-key 'normal 'org-mode-map (kbd "<leader>oAA") 'org-archive-subtree)
  (evil-define-key 'normal 'org-mode-map (kbd "<leader>oAT") 'org-toggle-archive-tag))

(use-package evil-collection
  :after evil
  :config
  (evil-collection-init))

;; parens
(use-package rainbow-delimiters
  :hook ((prog-mode . rainbow-delimiters-mode)))

(setq show-paren-delay 0)
(show-paren-mode)

(use-package paredit
  :hook ((emacs-lisp-mode . paredit-mode)
         (lisp-mode . paredit-mode)
         (ielm-mode . paredit-mode)
         (lisp-interaction-mode . paredit-mode)))

(use-package which-key :config (which-key-mode t))

(use-package nix-mode :mode "\\.nix\\'")
(use-package nix-drv-mode :mode "\\.drv\\'")

(use-package direnv
  :config (direnv-mode))

(use-package editorconfig
  :config (editorconfig-mode 1))

(use-package haskell-mode)
(use-package flycheck
  :init (global-flycheck-mode)
  :custom flycheck-keymap-prefix (kbd "<leader>!"))
(use-package lsp-mode
  :hook ((haskell-mode . lsp-deferred))
  :commands (lsp lsp-deferred)
  :custom
  lsp-modeline-code-actions-segments '() ; using lsp-ui-sideline instead
  :config
  (evil-define-key 'normal 'global
    (kbd "<leader>lwr") 'lsp-workspace-restart
    (kbd "<leader>lwq") 'lsp-workspace-shutdown
    (kbd "<leader>la=") 'lsp-format-buffer
    (kbd "<leader>lar") 'lsp-rename
    (kbd "<leader>laa") 'lsp-execute-code-action))
(use-package lsp-ui
  :after lsp-mode
  :custom
  lsp-ui-doc-enable t
  lsp-ui-doc-border "DimGray"
  lsp-ui-doc-delay 0.5
  :config
  (set-face-background 'lsp-ui-doc-background "WhiteSmoke")
  (set-face-foreground 'lsp-ui-sideline-code-action "SaddleBrown")
  (setq lsp-ui-sideline-code-actions-prefix "🔨 "
        lsp-ui-sideline-show-diagnostics nil
        lsp-ui-sideline-show-code-actions t) ; is :custom, but won't take effect?
  (evil-define-key 'normal lsp-ui-mode-map
    ;; TODO(sterni): emulate using xref for non-lsp?
    (kbd "<leader>lgr") 'lsp-ui-peek-find-references
    (kbd "<leader>lgd") 'lsp-ui-peek-find-definitions
    (kbd "<leader>lc") 'lsp-ui-flycheck-list))
(use-package lsp-haskell
  :after lsp-mode
  :custom
  lsp-haskell-formatting-provider "ormolu")

(use-package urweb-mode)
(use-package bqn-mode
  :mode "\\.bqn\\'"
  :custom bqn-mode-map-prefix "C-s-") ; probably rather using C-\
(use-package yaml-mode)
(use-package dockerfile-mode)
(use-package jq-mode
  :config (add-to-list 'auto-mode-alist '("\\.jq\\'" . jq-mode)))
(use-package rust-mode)
(use-package sly
  :after evil
  :hook ((sly-mrepl-mode . (lambda ()
                             (enable-paredit-mode)
                             (rainbow-delimiters-mode-enable))))
  :config
  (evil-define-key '(normal insert) sly-mrepl-mode-map (kbd "C-r") 'isearch-backward))

; TODO(sterni): https://github.com/NixOS/nixpkgs/pull/173893/files
; (use-package ada-mode)

(use-package rainbow-mode)
(use-package hl-todo
  :hook ((prog-mode . hl-todo-mode))
  :config
  (setq hl-todo-keyword-faces
        '(("TODO"  . "#FF0000")
          ("FIXME" . "#FF0000")
          ("HACK"  . "#7f7f7f")
          ("XXX"   . "#aa0000"))))

(use-package markdown-mode
  :commands (markdown-mode gfm-mode)
  :mode (("\\.md\\'" . markdown-mode)))
(use-package adoc-mode
  :mode (("\\.adoc\\'" . adoc-mode)))
(use-package languagetool
  :after evil
  :custom
  languagetool-java-arguments '("-Dfile.encoding=UTF-8")
  languagetool-default-language "en-GB"
  languagetool-mother-tongue "de-DE"
  :config
  (evil-define-key 'normal 'global (kbd "<leader>mll") 'languagetool-check)
  (evil-define-key 'normal 'global (kbd "<leader>mlc") 'languagetool-correct-at-point)
  (evil-define-key 'normal 'global (kbd "<leader>mls") 'languagetool-set-language)
  (evil-define-key 'normal 'global (kbd "<leader>mlr") 'languagetool-clear-suggestions)
  ;; Fill background of issues instead of just underlining to make it easier to read
  (set-face-background 'languagetool-issue-default "yellow")
  (set-face-background 'languagetool-issue-misspelling "red"))

(use-package deft
  :config
  ;; This is based on (car deft-extensions), but unfortunately the variable is
  ;; not re-bound in the hook defined by defcustom, so it is always "txt".
  (setq deft-default-extension "org")
  (setq deft-recursive t)
  (evil-define-key 'normal 'global (kbd "<leader>mn") 'deft)
  :custom
  deft-directory (expand-file-name "~/files/sync/org")
  deft-extensions '("org" "md" "txt" "tex"))

(unless (server-running-p)
  (server-start))

(require 'subscriptions) ; elfeed config
(require 'nix-inject)

(provide 'init)
