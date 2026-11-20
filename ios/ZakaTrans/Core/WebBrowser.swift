import SwiftUI
import WebKit

/// 网页里检测到的一个视频
struct DetectedVideo: Equatable {
    var url: String
    var poster: String
    var title: String
    var duration: Double
    var width: Int
    var height: Int

    var label: String {
        var s = "检测到视频"
        if duration > 1 {
            let m = Int(duration) / 60
            let sec = Int(duration) % 60
            s += String(format: " · %d:%02d", m, sec)
        }
        if width > 0 && height > 0 { s += " · \(width)×\(height)" }
        return s
    }
}

/// 要交给播放器的一份请求（带上网页的 Referer / Cookie / UA，防盗链的站才解得开）
struct VideoPlayRequest: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var title: String
    var poster: URL?
    var headers: [String: String]
}

// MARK: - 模型

final class WebBrowserModel: NSObject, ObservableObject {
    @Published private(set) var address = ""
    @Published private(set) var pageTitle = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var loading = false
    @Published private(set) var canBack = false
    @Published private(set) var canForward = false
    @Published private(set) var detected: DetectedVideo?
    @Published var hint = ""
    @Published var play: VideoPlayRequest?

    private(set) var webView: WKWebView!
    private var observations: [NSKeyValueObservation] = []
    private var mediaURLs: [String] = []
    private var lastVideo: DetectedVideo?

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    override init() {
        super.init()
        build()
    }

    deinit {
        observations.forEach { $0.invalidate() }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "zkvideo")
    }

    // MARK: 构建

    private func build() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        // 用户点一下就能播，不强制全屏接管（否则我们的字幕层就没地方放了）
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsPictureInPictureMediaPlayback = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.websiteDataStore = .default()

        let uc = WKUserContentController()
        uc.add(WeakMessageProxy(target: self), name: "zkvideo")
        uc.addUserScript(WKUserScript(source: Self.detectJS,
                                      injectionTime: .atDocumentEnd,
                                      forMainFrameOnly: false))
        cfg.userContentController = uc

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = Self.ua
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.keyboardDismissMode = .onDrag
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        webView = wv

        observations.append(wv.observe(\.estimatedProgress) { [weak self] v, _ in
            DispatchQueue.main.async { self?.progress = v.estimatedProgress }
        })
        observations.append(wv.observe(\.isLoading) { [weak self] v, _ in
            DispatchQueue.main.async { self?.loading = v.isLoading }
        })
        observations.append(wv.observe(\.canGoBack) { [weak self] v, _ in
            DispatchQueue.main.async { self?.canBack = v.canGoBack }
        })
        observations.append(wv.observe(\.canGoForward) { [weak self] v, _ in
            DispatchQueue.main.async { self?.canForward = v.canGoForward }
        })
    }

    // MARK: 导航

    func submit(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s) else { hint = "这个地址打不开"; return }
        open(u)
    }

    func open(_ url: URL) {
        detected = nil
        mediaURLs.removeAll()
        lastVideo = nil
        hint = ""
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { detected = nil; webView.reload() }
    func stopLoading() { webView.stopLoading() }

    func close() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "zkvideo")
    }

    // MARK: 视频

    fileprivate func onMessage(_ body: Any) {
        guard let d = body as? [String: Any], let type = d["type"] as? String else { return }

        if type == "media" {
            guard let u = d["url"] as? String, !u.isEmpty else { return }
            if !mediaURLs.contains(u) {
                mediaURLs.append(u)
                if mediaURLs.count > 24 { mediaURLs.removeFirst(mediaURLs.count - 24) }
            }
            // 视频是 blob（MSE 分片流）时，用抓到的真实流地址补上
            if var v = detected, v.url.isEmpty || v.url.hasPrefix("blob:") {
                v.url = u
                detected = v
                lastVideo = v
            }
            return
        }

        if type == "video" {
            guard let u = d["url"] as? String else { return }
            let v = DetectedVideo(
                url: u,
                poster: d["poster"] as? String ?? "",
                title: (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? pageTitle,
                duration: d["duration"] as? Double ?? 0,
                width: d["w"] as? Int ?? 0,
                height: d["h"] as? Int ?? 0
            )
            guard !u.isEmpty || !mediaURLs.isEmpty else { return }
            lastVideo = v
            detected = v
            return
        }
    }

    /// 让网页里的 <video>/<audio> 先停下来，避免和 App 播放器两路同时出声
    func pauseWebMedia() {
        webView.evaluateJavaScript("""
        (function(){ try {
          var els = document.querySelectorAll('video,audio');
          for (var i = 0; i < els.length; i++) { try { els[i].pause(); } catch(e) {} }
        } catch(e) {} })();
        """, completionHandler: nil)
    }

    /// 从抓到的媒体地址里挑一个能整段播的：
    /// HLS 主播放列表（m3u8）优先，其次 mp4 这类整文件，分片地址一律不用。
    private var bestMediaURL: String? {
        if let hls = mediaURLs.last(where: { $0.lowercased().contains("m3u8") }) { return hls }
        if let f = mediaURLs.last(where: {
            let l = $0.lowercased()
            return l.contains(".mp4") || l.contains(".mov") || l.contains(".webm")
        }) { return f }
        return nil
    }

    /// 点「用字幕播放」：把地址、Referer、Cookie 一起整理好
    func startPlaying() {
        pauseWebMedia()
        guard var v = detected ?? lastVideo else { hint = "还没检测到视频"; return }
        // 空地址、blob:、或者抓到的是分片/未知格式 —— 都换成能整段播的那个
        let l = v.url.lowercased()
        let whole = l.contains("m3u8") || l.contains(".mp4") || l.contains(".mov") || l.contains(".webm")
        if v.url.isEmpty || v.url.hasPrefix("blob:") || !whole {
            if let m = bestMediaURL { v.url = m }
        }
        guard !v.url.isEmpty, !v.url.hasPrefix("blob:"), let u = URL(string: v.url) else {
            hint = "这个视频的地址拿不到，回网页里点播放再试一次"
            return
        }

        var headers: [String: String] = ["User-Agent": Self.ua]
        if let page = webView.url?.absoluteString, !page.isEmpty { headers["Referer"] = page }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let host = u.host ?? ""
            let picked = cookies.filter { c in
                if host.isEmpty { return false }
                let h = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                return host == h || host.hasSuffix("." + h)
            }
            if !picked.isEmpty {
                headers["Cookie"] = picked.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
            DispatchQueue.main.async {
                self.play = VideoPlayRequest(
                    url: u,
                    title: v.title.isEmpty ? self.pageTitle : v.title,
                    poster: v.poster.isEmpty ? nil : URL(string: v.poster),
                    headers: headers
                )
            }
        }
    }

    // MARK: 注入脚本

    private static let detectJS = """
    (function(){
      if (window.__zkHook) return; window.__zkHook = 1;
      var lastKey = '', lastMedia = '';
      function post(o){ try { window.webkit.messageHandlers.zkvideo.postMessage(o); } catch(e) {} }
      function abs(u){
        if (!u) return '';
        try { return new URL(u, location.href).href; } catch(e) { return String(u); }
      }
      function looksMedia(u){
        if (!u) return false;
        var s = String(u).toLowerCase();
        if (s.indexOf('blob:') === 0 || s.indexOf('data:') === 0) return false;
        if (/\\.(m3u8|mp4|flv|mkv|webm|mov)([?#]|$)/.test(s)) return true;
        if (s.indexOf('m3u8') >= 0) return true;
        if (s.indexOf('/hls/') >= 0) return true;
        return false;
      }
      function hookMedia(u){
        u = abs(u); if (!looksMedia(u)) return; if (u === lastMedia) return;
        lastMedia = u; post({type:'media', url:u});
      }
      try {
        var of = window.fetch;
        if (of) window.fetch = function(input){
          try { hookMedia(typeof input === 'string' ? input : (input && input.url)); } catch(e) {}
          return of.apply(this, arguments);
        };
      } catch(e) {}
      try {
        var oo = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(m, u){
          try { hookMedia(u); } catch(e) {}
          return oo.apply(this, arguments);
        };
      } catch(e) {}
      try {
        var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (d && d.set) {
          Object.defineProperty(HTMLMediaElement.prototype, 'src', {
            set: function(v){ try { hookMedia(v); } catch(e) {} return d.set.call(this, v); },
            get: d.get, configurable: true
          });
        }
      } catch(e) {}

      function scan(){
        var vs = document.getElementsByTagName('video');
        for (var i = 0; i < vs.length; i++) {
          var v = vs[i];
          var u = v.currentSrc || v.src || '';
          var poster = v.poster || '';
          var dur = (isFinite(v.duration) ? v.duration : 0);
          var key = u + '|' + poster + '|' + Math.round(dur);
          if (key === lastKey) continue;
          lastKey = key;
          post({type:'video', url: abs(u), poster: abs(poster), duration: dur,
                w: v.videoWidth || 0, h: v.videoHeight || 0, title: document.title || ''});
        }
      }
      setInterval(scan, 1000);
      document.addEventListener('click', function(){ setTimeout(scan, 350); }, true);
      setTimeout(scan, 700);
    })();
    """
}

// MARK: - 代理

/// WKUserContentController 会强引用 handler，模型反过来持有 webView，
/// 直接注册自己就是循环引用，用一层弱代理隔开。
private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebBrowserModel?
    init(target: WebBrowserModel) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.name == "zkvideo" else { return }
        DispatchQueue.main.async { self.target?.onMessage(m.body) }
    }
}

// MARK: - 导航代理

extension WebBrowserModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        pageTitle = wv.title ?? ""
        address = wv.url?.absoluteString ?? address
        loading = false
        progress = 1
        wv.evaluateJavaScript("document.title || ''") { [weak self] v, _ in
            if let t = v as? String, !t.isEmpty { self?.pageTitle = t }
        }
        // 有些站把视频放在 iframe 里、脚本注入晚一拍，进页面后再补扫一次
        wv.evaluateJavaScript("window.dispatchEvent(new Event('resize'))", completionHandler: nil)
    }

    func webView(_ wv: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
        loading = true
        detected = nil
        address = wv.url?.absoluteString ?? address
    }

    func webView(_ wv: WKWebView, didFail nav: WKNavigation!, withError e: Error) {
        loading = false
        if (e as NSError).code != NSURLErrorCancelled { hint = "这页没打开：\(e.localizedDescription)" }
    }

    func webView(_ wv: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) {
        loading = false
        if (e as NSError).code != NSURLErrorCancelled { hint = "这页没打开：\(e.localizedDescription)" }
    }

    /// target="_blank" 的链接（视频站「点开播放」经常这样）就在本窗口里开
    func webView(_ wv: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, action.request.url != nil { wv.load(action.request) }
        return nil
    }

    /// 直接点一个 mp4 / m3u8 链接时，不让它在网页里开，而是接过来用带字幕的播放器
    func webView(_ wv: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let mime = response.response.mimeType?.lowercased() ?? ""
        let ext = response.response.url?.pathExtension.lowercased() ?? ""
        let isMedia = mime.hasPrefix("video/") || mime.contains("mpegurl")
            || ["mp4", "m3u8", "mov", "m4v", "webm"].contains(ext)
        if response.isForMainFrame && isMedia, let u = response.response.url {
            decisionHandler(.cancel)
            detected = DetectedVideo(url: u.absoluteString, poster: "", title: pageTitle,
                                     duration: 0, width: 0, height: 0)
            return
        }
        decisionHandler(.allow)
    }
}
