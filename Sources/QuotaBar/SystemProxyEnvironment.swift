import CFNetwork
import Foundation

enum SystemProxyEnvironment {
    static func current() -> [String: String] {
        guard let unmanaged = CFNetworkCopySystemProxySettings() else { return [:] }
        let settings = unmanaged.takeRetainedValue() as NSDictionary

        if isEnabled(settings[kCFNetworkProxiesSOCKSEnable]),
           let host = settings[kCFNetworkProxiesSOCKSProxy] as? String,
           let port = number(settings[kCFNetworkProxiesSOCKSPort]) {
            let value = "socks5h://\(host):\(port)"
            return ["ALL_PROXY": value, "all_proxy": value]
        }

        if isEnabled(settings[kCFNetworkProxiesHTTPSEnable]),
           let host = settings[kCFNetworkProxiesHTTPSProxy] as? String,
           let port = number(settings[kCFNetworkProxiesHTTPSPort]) {
            let value = "http://\(host):\(port)"
            return ["HTTPS_PROXY": value, "https_proxy": value]
        }

        if isEnabled(settings[kCFNetworkProxiesHTTPEnable]),
           let host = settings[kCFNetworkProxiesHTTPProxy] as? String,
           let port = number(settings[kCFNetworkProxiesHTTPPort]) {
            let value = "http://\(host):\(port)"
            return ["HTTP_PROXY": value, "http_proxy": value]
        }
        return [:]
    }

    private static func isEnabled(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue == true
    }

    private static func number(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
