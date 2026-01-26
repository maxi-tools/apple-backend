// WuiWebView.swift
// WebView component - WKWebView wrapper for WaterUI
//
// # Layout Behavior
// WebView is greedy - it expands to fill all available space.

import CWaterUI
import Security
import WebKit
import os

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "WuiWebView")

// MARK: - WebView Wrapper

/// Wraps a WKWebView and implements FFI function pointers for Rust integration.
@MainActor
final class WebViewWrapper: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    private var eventCallback: CWaterUI.WuiFn_WuiWebViewEvent?
    private var userScripts: [(String, CWaterUI.WuiScriptInjectionTime)] = []
    private var redirectsEnabled = true
    private var lastNavigationUrl: String?
    private var progressObservation: NSKeyValueObservation?
    private var messageHandlers: [String: CWaterUI.WuiFn_WuiWebViewMessage] = [:]
    private var installedBridge = false
    private var cachedCookies: String = ""

    override init() {
        let config = WKWebViewConfiguration()
        #if canImport(UIKit)
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
        #endif

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) {
            [weak self] _, change in
            guard let self else { return }
            let progress = Float(change.newValue ?? 0.0)
            Task { @MainActor in
                self.emitLoading(progress)
            }
        }
    }

    private static func dropWuiStr(_ s: CWaterUI.WuiStr) {
        s._0.vtable.drop(s._0.data)
    }

    private struct JsBridge {
        static func baseScript() -> String {
            // Provides a global request/response registry and base64 helpers.
            // Handlers installed later can depend on `window.__wateruiResolve`.
            """
            (function(){
              if (window.__waterui) { return; }
              function toBase64Utf8(s){ return btoa(unescape(encodeURIComponent(s))); }
              function fromBase64Utf8(b64){ return decodeURIComponent(escape(atob(b64))); }
              window.__waterui = { pending: Object.create(null), toBase64Utf8: toBase64Utf8, fromBase64Utf8: fromBase64Utf8 };
              window.__wateruiResolve = function(id, ok, payload){
                var p = window.__waterui.pending[id];
                if (!p) { return; }
                delete window.__waterui.pending[id];
                if (ok) { p.resolve(payload); } else { p.reject(payload); }
              };
            })();
            """
        }

        static func handlerScript(name: String) -> String {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            return """
            (function(){
              var name = '\(escaped)';
              if (!window.__waterui || !window.__wateruiResolve) { return; }
              if (window[name] && window[name].__wateruiWrapped) { return; }
              function send(data){
                var id = String(Date.now()) + '_' + String(Math.random()).slice(2);
                var text = (typeof data === 'string') ? data : JSON.stringify(data);
                var b64 = window.__waterui.toBase64Utf8(text);
                return new Promise(function(resolve, reject){
                  window.__waterui.pending[id] = { resolve: resolve, reject: reject };
                  window.webkit.messageHandlers[name].postMessage({ id: id, payload: b64 });
                });
              }
              window[name] = {
                __wateruiWrapped: true,
                postMessageRaw: function(data){
                  return send(data);
                },
                postMessage: function(data){
                  return send(data).then(function(replyB64){
                    return window.__waterui.fromBase64Utf8(replyB64);
                  });
                }
              };
            })();
            """
        }
    }

    private func ensureBridgeInstalled() {
        guard !installedBridge else { return }
        installedBridge = true
        injectScript(JsBridge.baseScript(), time: WuiScriptInjectionTime_DocumentStart)
    }

    private func ensureHandlerScriptInstalled(name: String) {
        ensureBridgeInstalled()
        injectScript(JsBridge.handlerScript(name: name), time: WuiScriptInjectionTime_DocumentStart)
    }

    private final class MessageReplyContext {
        weak var wrapper: WebViewWrapper?
        let requestId: String

        init(wrapper: WebViewWrapper, requestId: String) {
            self.wrapper = wrapper
            self.requestId = requestId
        }
    }

    private static func jsonQuoted(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        // Strip [ and ] to get the single JSON string token.
        return String(text.dropFirst().dropLast())
    }

    private static let messageReplyCallback: @convention(c) (
        UnsafeMutableRawPointer?,
        Bool,
        CWaterUI.WuiStr
    ) -> Void = { data, success, result in
        guard let data else { return }
        let ctx = Unmanaged<MessageReplyContext>.fromOpaque(data).takeRetainedValue()
        guard let wrapper = ctx.wrapper else { return }

        let payload = WuiStr(result).toString()
        let id = WebViewWrapper.jsonQuoted(ctx.requestId)
        let ok = success ? "true" : "false"
        let body = WebViewWrapper.jsonQuoted(payload)
        let js = "window.__wateruiResolve(\(id), \(ok), \(body));"
        Task { @MainActor in
            wrapper.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func addHandler(_ name: String, callback: CWaterUI.WuiFn_WuiWebViewMessage) {
        // Replace existing handler if present.
        if let existing = messageHandlers[name] {
            existing.drop?(existing.data)
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        messageHandlers[name] = callback
        webView.configuration.userContentController.add(self, name: name)
        ensureHandlerScriptInstalled(name: name)
    }

    func removeHandler(_ name: String) {
        if let existing = messageHandlers.removeValue(forKey: name) {
            existing.drop?(existing.data)
        }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let name = message.name
        let body = message.body
        Task { @MainActor [weak self] in
            self?.handleScriptMessage(name: name, body: body)
        }
    }

    @MainActor
    private func handleScriptMessage(name: String, body: Any) {
        guard let callback = messageHandlers[name] else { return }

        // Expected payload: { id: string, payload: base64(string) }.
        let dict = body as? [String: Any]
        let requestId = dict?["id"] as? String
        let payloadB64 = dict?["payload"] as? String

        guard let requestId, let payloadB64 else { return }

        let replyCtx = Unmanaged.passRetained(MessageReplyContext(wrapper: self, requestId: requestId)).toOpaque()
        let reply = CWaterUI.WuiJsCallback(data: replyCtx, call: messageReplyCallback)
        let msg = CWaterUI.WuiWebViewMessage(
            payload_base64: WuiStr(string: payloadB64).intoInner(),
            reply: reply
        )
        callback.call?(callback.data, msg)
    }

    func setCookie(_ setCookieHeaderValue: String) {
        let trimmed = setCookieHeaderValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url = webView.url ?? URL(string: "https://localhost/")!
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": trimmed], for: url)
        guard !cookies.isEmpty else { return }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies {
            store.setCookie(cookie, completionHandler: nil)
        }
        refreshCookieCache()
    }

    func refreshCookieCache() {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let lines = cookies.map { cookie in
                var parts: [String] = ["\(cookie.name)=\(cookie.value)"]
                if let domain = cookie.domain as String? { parts.append("Domain=\(domain)") }
                if let path = cookie.path as String? { parts.append("Path=\(path)") }
                if let expires = cookie.expiresDate {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                    parts.append("Expires=\(formatter.string(from: expires))")
                }
                if cookie.isSecure { parts.append("Secure") }
                if cookie.isHTTPOnly { parts.append("HttpOnly") }
                return parts.joined(separator: "; ")
            }
            self.cachedCookies = lines.joined(separator: "\n")
        }
    }

    // MARK: - Navigation

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func goTo(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }
        webView.load(URLRequest(url: url))
    }

    func stop() {
        webView.stopLoading()
    }

    func refresh() {
        webView.reload()
    }

    // MARK: - State

    func canGoBack() -> Bool {
        webView.canGoBack
    }

    func canGoForward() -> Bool {
        webView.canGoForward
    }

    // MARK: - Configuration

    func setUserAgent(_ userAgent: String) {
        let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        webView.customUserAgent = trimmed.isEmpty ? nil : trimmed
    }

    func setRedirectsEnabled(_ enabled: Bool) {
        redirectsEnabled = enabled
    }

    func injectScript(_ script: String, time: CWaterUI.WuiScriptInjectionTime) {
        let injectionTime: WKUserScriptInjectionTime =
            time == WuiScriptInjectionTime_DocumentStart
            ? .atDocumentStart
            : .atDocumentEnd

        let userScript = WKUserScript(
            source: script,
            injectionTime: injectionTime,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(userScript)
        userScripts.append((script, time))
    }

    // MARK: - Event Watching

    func setEventCallback(_ callback: CWaterUI.WuiFn_WuiWebViewEvent) {
        if let old = eventCallback {
            old.drop?(old.data)
        }
        self.eventCallback = callback
    }

    private func emitEvent(_ event: CWaterUI.WuiWebViewEvent) {
        guard let callback = eventCallback else { return }
        callback.call?(callback.data, event)
    }

    private func emitLoading(_ progress: Float) {
        let event = CWaterUI.WuiWebViewEvent(
            event_type: WuiWebViewEventType_Loading,
            url: WuiStr(string: "").intoInner(),
            url2: WuiStr(string: "").intoInner(),
            message: WuiStr(string: "").intoInner(),
            progress: progress,
            can_go_back: false,
            can_go_forward: false
        )
        emitEvent(event)
    }

    private func emitStateChanged() {
        let event = CWaterUI.WuiWebViewEvent(
            event_type: WuiWebViewEventType_StateChanged,
            url: WuiStr(string: "").intoInner(),
            url2: WuiStr(string: "").intoInner(),
            message: WuiStr(string: "").intoInner(),
            progress: 0,
            can_go_back: webView.canGoBack,
            can_go_forward: webView.canGoForward
        )
        emitEvent(event)
    }

    private func emitSslError(_ urlString: String, message: String) {
        let event = CWaterUI.WuiWebViewEvent(
            event_type: WuiWebViewEventType_SslError,
            url: WuiStr(string: urlString).intoInner(),
            url2: WuiStr(string: "").intoInner(),
            message: WuiStr(string: message).intoInner(),
            progress: 0,
            can_go_back: false,
            can_go_forward: false
        )
        emitEvent(event)
    }

    private func emitWillNavigate(_ urlString: String, allowRepeat: Bool) {
        guard !urlString.isEmpty else { return }
        if !allowRepeat, lastNavigationUrl == urlString {
            return
        }
        lastNavigationUrl = urlString
        let event = CWaterUI.WuiWebViewEvent(
            event_type: WuiWebViewEventType_WillNavigate,
            url: WuiStr(string: urlString).intoInner(),
            url2: WuiStr(string: "").intoInner(),
            message: WuiStr(string: "").intoInner(),
            progress: 0,
            can_go_back: false,
            can_go_forward: false
        )
        emitEvent(event)
    }

    // MARK: - JavaScript

    func runJavaScript(_ script: String, callback: CWaterUI.WuiJsCallback) {
        webView.evaluateJavaScript(script) { result, error in
            let callbackData = callback.data
            let callbackFn = callback.call

            if let error = error {
                let errorMsg = error.localizedDescription
                let errorStr = WuiStr(string: errorMsg).intoInner()
                callbackFn?(callbackData, false, errorStr)
            } else {
                let resultStr: String
                if let result = result {
                    // JSONSerialization raises NSException on invalid objects, so validate first.
                    if JSONSerialization.isValidJSONObject(result),
                        let jsonData = try? JSONSerialization.data(withJSONObject: result),
                        let jsonStr = String(data: jsonData, encoding: .utf8)
                    {
                        resultStr = jsonStr
                    } else {
                        resultStr = String(describing: result)
                    }
                } else {
                    resultStr = "null"
                }
                let wuiStr = WuiStr(string: resultStr).intoInner()
                callbackFn?(callbackData, true, wuiStr)
            }
        }
    }

    // MARK: - FFI Handle Creation

    func toFFIHandle() -> CWaterUI.WuiWebViewHandle {
        let ptr = Unmanaged.passRetained(self).toOpaque()

        return CWaterUI.WuiWebViewHandle(
            data: ptr,
            go_back: { rawPtr in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in wrapper.goBack() }
            },
            go_forward: { rawPtr in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in wrapper.goForward() }
            },
            go_to: { rawPtr, url in
                guard let rawPtr = rawPtr else {
                    WebViewWrapper.dropWuiStr(url)
                    return
                }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in
                    let urlString = WuiStr(url).toString()
                    wrapper.goTo(urlString)
                }
            },
            stop: { rawPtr in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in wrapper.stop() }
            },
            refresh: { rawPtr in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in wrapper.refresh() }
            },
            can_go_back: { rawPtr in
                guard let rawPtr = rawPtr else { return false }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                if Thread.isMainThread {
                    return wrapper.webView.canGoBack
                }
                return DispatchQueue.main.sync {
                    wrapper.webView.canGoBack
                }
            },
            can_go_forward: { rawPtr in
                guard let rawPtr = rawPtr else { return false }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                if Thread.isMainThread {
                    return wrapper.webView.canGoForward
                }
                return DispatchQueue.main.sync {
                    wrapper.webView.canGoForward
                }
            },
            set_user_agent: { rawPtr, userAgent in
                guard let rawPtr = rawPtr else {
                    WebViewWrapper.dropWuiStr(userAgent)
                    return
                }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in
                    let uaString = WuiStr(userAgent).toString()
                    wrapper.setUserAgent(uaString)
                }
            },
            set_redirects_enabled: { rawPtr, enabled in
                guard let rawPtr = rawPtr else { return }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in wrapper.setRedirectsEnabled(enabled) }
            },
            inject_script: { rawPtr, script, time in
                guard let rawPtr = rawPtr else {
                    WebViewWrapper.dropWuiStr(script)
                    return
                }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in
                    let scriptString = WuiStr(script).toString()
                    wrapper.injectScript(scriptString, time: time)
                }
            },
            watch: { rawPtr, callback in
                guard let rawPtr = rawPtr else {
                    callback.drop?(callback.data)
                    return
                }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in wrapper.setEventCallback(callback) }
            },
            add_handler: { rawPtr, name, callback in
                guard let rawPtr = rawPtr else {
                    WebViewWrapper.dropWuiStr(name)
                    callback.drop?(callback.data)
                    return
                }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in
                    let nameString = WuiStr(name).toString()
                    wrapper.addHandler(nameString, callback: callback)
                }
            },
            remove_handler: { rawPtr, name in
                guard let rawPtr = rawPtr else {
                    WebViewWrapper.dropWuiStr(name)
                    return
                }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in
                    let nameString = WuiStr(name).toString()
                    wrapper.removeHandler(nameString)
                }
            },
            set_cookie: { rawPtr, cookie in
                guard let rawPtr = rawPtr else {
                    WebViewWrapper.dropWuiStr(cookie)
                    return
                }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in
                    let cookieString = WuiStr(cookie).toString()
                    wrapper.setCookie(cookieString)
                }
            },
            get_cookies: { rawPtr in
                guard let rawPtr = rawPtr else {
                    return WuiStr(string: "").intoInner()
                }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                return WuiStr(string: wrapper.cachedCookies).intoInner()
            },
            run_javascript: { rawPtr, script, callback in
                guard let rawPtr = rawPtr else {
                    WebViewWrapper.dropWuiStr(script)
                    let msg = WuiStr(string: "WebView not available").intoInner()
                    callback.call?(callback.data, false, msg)
                    return
                }
                let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).takeUnretainedValue()
                Task { @MainActor in
                    let scriptString = WuiStr(script).toString()
                    wrapper.runJavaScript(scriptString, callback: callback)
                }
            },
            drop: { rawPtr in
                guard let rawPtr = rawPtr else { return }
                // Release the retained reference
                Unmanaged<WebViewWrapper>.fromOpaque(rawPtr).release()
            }
        )
    }

    deinit {
        for (_, cb) in messageHandlers {
            cb.drop?(cb.data)
        }
        messageHandlers.removeAll()
        if let cb = eventCallback {
            cb.drop?(cb.data)
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebViewWrapper: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        Task { @MainActor in
            let requestUrl = navigationAction.request.url?.absoluteString ?? ""
            let allowRepeat =
                navigationAction.navigationType == .reload
                || navigationAction.navigationType == .backForward
                || navigationAction.navigationType == .formSubmitted
                || navigationAction.navigationType == .formResubmitted

            if navigationAction.targetFrame == nil {
                emitWillNavigate(requestUrl, allowRepeat: allowRepeat)
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame?.isMainFrame ?? true {
                emitWillNavigate(requestUrl, allowRepeat: allowRepeat)
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        Task { @MainActor in
            guard navigationResponse.isForMainFrame else {
                decisionHandler(.allow)
                return
            }
            guard let response = navigationResponse.response as? HTTPURLResponse else {
                decisionHandler(.allow)
                return
            }

            let statusCode = response.statusCode
            guard (300..<400).contains(statusCode) else {
                decisionHandler(.allow)
                return
            }

            if !redirectsEnabled {
                let fromUrl = response.url?.absoluteString ?? ""
                let location = response.allHeaderFields.first { key, _ in
                    (key as? String)?.caseInsensitiveCompare("location") == .orderedSame
                }?.value as? String ?? ""
                let toUrl = URL(string: location, relativeTo: response.url)?.absoluteString
                    ?? location

                let event = CWaterUI.WuiWebViewEvent(
                    event_type: WuiWebViewEventType_Redirect,
                    url: WuiStr(string: fromUrl).intoInner(),
                    url2: WuiStr(string: toUrl).intoInner(),
                    message: WuiStr(string: "").intoInner(),
                    progress: 0,
                    can_go_back: false,
                    can_go_forward: false
                )
                emitEvent(event)
                webView.stopLoading()
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        Task { @MainActor in
            let urlStr = webView.url?.absoluteString ?? ""
            emitWillNavigate(urlStr, allowRepeat: false)
            emitLoading(0)
            emitStateChanged()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let event = CWaterUI.WuiWebViewEvent(
                event_type: WuiWebViewEventType_Loaded,
                url: WuiStr(string: "").intoInner(),
                url2: WuiStr(string: "").intoInner(),
                message: WuiStr(string: "").intoInner(),
                progress: 1.0,
                can_go_back: false,
                can_go_forward: false
            )
            emitEvent(event)
            emitStateChanged()
            refreshCookieCache()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        Task { @MainActor in
            let event = CWaterUI.WuiWebViewEvent(
                event_type: WuiWebViewEventType_Error,
                url: WuiStr(string: "").intoInner(),
                url2: WuiStr(string: "").intoInner(),
                message: WuiStr(string: error.localizedDescription).intoInner(),
                progress: 0,
                can_go_back: false,
                can_go_forward: false
            )
            emitEvent(event)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            let event = CWaterUI.WuiWebViewEvent(
                event_type: WuiWebViewEventType_Error,
                url: WuiStr(string: "").intoInner(),
                url2: WuiStr(string: "").intoInner(),
                message: WuiStr(string: error.localizedDescription).intoInner(),
                progress: 0,
                can_go_back: false,
                can_go_forward: false
            )
            emitEvent(event)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) ->
            Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        {
            var trustError: CFError?
            let ok = SecTrustEvaluateWithError(serverTrust, &trustError)
            if ok {
                let credential = URLCredential(trust: serverTrust)
                Task { @MainActor in completionHandler(.useCredential, credential) }
                return
            }

            let urlStr = webView.url?.absoluteString ?? ""
            let message = (trustError as Error?)?.localizedDescription ?? "SSL certificate error"
            Task { @MainActor in
                emitSslError(urlStr, message: message)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        Task { @MainActor in completionHandler(.performDefaultHandling, nil) }
    }
}

// MARK: - WKUIDelegate

extension WebViewWrapper: WKUIDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        Task { @MainActor in
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
        }
        return nil
    }
}

// MARK: - Controller Installation

/// Installs the WebView controller into the environment.
/// Call this during app initialization before waterui_app().
@MainActor
public func installWebViewController(env: OpaquePointer?) {
    let createFn: @convention(c) () -> CWaterUI.WuiWebViewHandle = {
        // This runs on whatever thread Rust calls it from.
        // Ensure WebView creation happens on the main thread without blocking it.
        if Thread.isMainThread {
            return WebViewWrapper().toFFIHandle()
        }
        return DispatchQueue.main.sync {
            WebViewWrapper().toFFIHandle()
        }
    }
    waterui_env_install_webview_controller(env, createFn)
}

// MARK: - WebView Component for Rendering

/// Native component that renders a WebView in the view hierarchy.
@MainActor
final class WuiWebViewComponent: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_webview_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both
    private var webViewWrapper: WebViewWrapper?

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        super.init(frame: .zero)

        logger.warning("WuiWebViewComponent init started")

        // Get the WuiWebView opaque pointer
        let wuiWebView = waterui_force_as_webview(anyview)
        logger.warning("Got WuiWebView pointer: \(String(describing: wuiWebView))")

        // Get the native handle pointer (points to WebViewWrapper)
        let handlePtr = waterui_webview_native_handle(wuiWebView)
        logger.warning("Got native handle pointer: \(String(describing: handlePtr))")

        guard let handlePtr = handlePtr else {
            logger.error("ERROR: WebView native handle is null - downcast failed!")
            // Clean up the WuiWebView
            waterui_drop_web_view(wuiWebView)
            return
        }

        // Get the WebViewWrapper from the raw pointer
        let wrapper = Unmanaged<WebViewWrapper>.fromOpaque(handlePtr).takeUnretainedValue()
        self.webViewWrapper = wrapper
        logger.warning(
            "Got WebViewWrapper, webView URL: \(String(describing: wrapper.webView.url))")

        // Clean up the WuiWebView after we have a strong reference to the wrapper
        waterui_drop_web_view(wuiWebView)

        // Add the WKWebView as a subview
        let webView = wrapper.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        logger.warning("WuiWebViewComponent setup complete - added WKWebView as subview")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // WebView is greedy - it takes all available space
        let width = proposal.width.map { CGFloat($0) } ?? 320
        let height = proposal.height.map { CGFloat($0) } ?? 480
        return CGSize(width: width, height: height)
    }
}
