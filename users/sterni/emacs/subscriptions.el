;;; elfeed
(use-package elfeed
  :after evil
  :config
  ;; elfeed bindings for evil
  (evil-define-key 'normal 'global (kbd "<leader>mf") 'elfeed)
  (evil-define-key '(normal visual) elfeed-search-mode-map
    (kbd "o") 'elfeed-search-browse-url
    (kbd "r") 'elfeed-search-untag-all-unread
    (kbd "u") 'elfeed-search-tag-all-unread
    (kbd "ff") 'elfeed-search-fetch
    (kbd "fc") 'elfeed-db-compact)
  ;; elfeed subscriptions
  (setq elfeed-feeds
        (append
         ;; immutable subscriptions tracked in git
         '(("https://repology.org/maintainer/sternenseemann%40systemli.org/feed-for-repo/nix_unstable/atom" dashboard releases)
           ("https://www.stackage.org/feed" dashboard releases)
           ("https://text.causal.agency/feed.atom" blog)
           ("http://xsteadfastx.org/feed/" blog cool-and-nice)
           ("https://tvl.fyi/feed.atom" blog cool-and-nice)
           ("https://hannes.robur.coop/atom" blog)
           ("https://stevelosh.com/rss.xml" blog)
           ("https://blog.benjojo.co.uk/rss.xml" blog)
           ("https://leahneukirchen.org/blog/index.atom" blog cool-and-nice)
           ("https://leahneukirchen.org/trivium/index.atom" blog links cool-and-nice)
           ("https://firefly.nu/feeds/all.atom.xml" blog cool-and-nice)
           ("https://tazj.in/feed.atom" blog cool-and-nice)
           ("https://alyssa.is/feed.xml" blog cool-and-nice)
           ("https://eta.st/feed.xml" blog cool-and-nice)
           ("https://spectrum-os.org/git/www/atom/bibliography.html" links blog)
           ("https://vulns.xyz/feed.xml" blog)
           ("https://www.german-foreign-policy.com/?type=9818" news)
           ("https://compilercrim.es/rss.xml" blog)
           ("http://blog.nullspace.io/feed.xml" blog)
           ("https://blog.kingcons.io/rss.xml" blog)
           ("https://www.imperialviolet.org/iv-rss.xml" blog)
           ("http://shitopenlabsays.tumblr.com/rss" openlab)
           ("https://kristaps.bsd.lv/lowdown/atom.xml" releases)
           ("http://0pointer.net/blog/index.atom" blog)
           ("https://emacsninja.com/feed.atom" blog)
           ("https://emacshorrors.com/feed.atom" blog)
           ("http://therealmntmn.tumblr.com/rss" blog)
           ("http://blog.duangle.com/feeds/posts/default" blog)
           ("http://ccc.de/de/rss/updates.xml" news)
           ("http://ffaaaffaffaffaa.tumblr.com/rss" pictures)
           ("http://fotografiona.tumblr.com/rss" pictures)
           ("http://guteaussicht.org/rss" pictures)
           ("http://konvergenzfehler.de/feed/" blog)
           ("https://markuscisler.com/feed.xml" blog)
           ("http://www.whvrt.de/rss" pictures)
           ("https://barnslig.eu/feed/" blog)
           ("https://mgsloan.com/feed.xml" blog)
           ("http://beza1e1.tuxen.de/blog_en.atom" blog)
           ("https://anchor.fm/s/94bb000/podcast/rss" podcast))
           ;; http://www.wollenzin.de/feed/ ;_;

         ;; add more feeds from an untracked file in $HOME
         (let ((file (concat (getenv "HOME")
                             "/.config/emacs-custom/mutable-subscriptions.el")))
           (when (file-exists-p file)
             (read (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string))))))))

(provide 'subscriptions)
