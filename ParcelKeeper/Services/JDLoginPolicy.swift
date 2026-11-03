import Foundation

/// A saved PC session is not a mobile credential. Resume uses only a validated
/// snapshot in an isolated store; cancelled/unverified live stores are never seeded.
enum JDLoginMode: Equatable { case resume, switchAccount }

struct JDLoginPolicy {
    let cookies: [TaobaoTrialCookie]
    let initialURL: URL?
    let pcSessionSaved: Bool

    init(mode: JDLoginMode, cookies: [TaobaoTrialCookie]) {
        if mode == .switchAccount {
            self.cookies = []; initialURL = MallPlatform.jd.loginURL; pcSessionSaved = false
        } else if MallSession.hasJDPCSession(cookies) {
            self.cookies = []; initialURL = nil; pcSessionSaved = true
        } else {
            let mobile = cookies.filter { cookie in cookie.name != "thor" && MallSession.valid(cookie, platform: .jd) }
            let valid = MallSession.hasLoginCredentials(mobile, platform: .jd)
            self.cookies = valid ? mobile : []
            initialURL = valid ? MallPlatform.jd.ordersURL : MallPlatform.jd.loginURL
            pcSessionSaved = false
        }
    }

    /// Never retain/log arbitrary NSError domain, userInfo, URL or response text.
    static func navigationFailure(_ error: Error) -> Error {
        let value = error as NSError
        if value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled { return CancellationError() }
        if value.domain == NSURLErrorDomain && value.code == NSURLErrorTimedOut {
            return JDLoggedError(reason: .timeout, stage: .jdLogin)
        }
        return JDLoggedError(reason: .network, stage: .jdLogin)
    }
}
