//
//  ServerInstaller+SelfCheck.swift
//  geekIpa
//
//  职责：安装服务器自检。
//  itms-services 把清单 URL 交给系统后，iOS 失败时**不会**给 App 任何回调——
//  所以我们在打开 itms 链接之前，先用 URLSession 自己拉一遍清单：
//  - 拉得动：TLS/端口/路径全部正常，安装大概率成功
//  - 拉不动：立刻把错误（TLS 证书失效/连接被拒/超时）打到日志，用户当场能看到原因
//

import Foundation

extension ServerInstaller {

	/// 自检结果
	struct SelfCheckResult {
		let ok: Bool
		let detail: String
	}

	/// 用 URLSession 预拉安装清单，验证链路
	/// - Parameter timeout: 超时秒数（默认 8 秒，避免卡死）
	@discardableResult
	func selfCheck(timeout: TimeInterval = 8) async -> SelfCheckResult {
		let logger = InstallLogger.shared
		let url = plistEndpoint

		logger.info("自检", "预拉取安装清单: \(url.absoluteString)")

		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = timeout
		// 自签/域名证书在本机环回场景下需要跳过评估（itmsd 系统进程有它自己的校验，
		// 这里的自检只验证"链路是否通"，安全性不影响）
		let session = URLSession(configuration: config, delegate: InsecureSkipDelegate(), delegateQueue: nil)
		defer { session.invalidateAndCancel() }

		do {
			let (data, response) = try await session.data(from: url)
			let code = (response as? HTTPURLResponse)?.statusCode ?? -1
			if code == 200, !data.isEmpty {
				// 校验清单内容是真 plist
				let looksPlist = data.starts(with: Data("<?xml".utf8)) || data.starts(with: Data("bplist".utf8))
				if looksPlist {
					logger.success("自检", "清单可访问（HTTP 200，\(data.count) 字节），链路正常")
					return SelfCheckResult(ok: true, detail: "清单可访问")
				} else {
					logger.warning("自检", "清单返回 200 但内容不是 plist（\(data.count) 字节）")
					return SelfCheckResult(ok: false, detail: "清单内容格式异常")
				}
			} else {
				logger.error("自检", "清单返回 HTTP \(code)")
				return SelfCheckResult(ok: false, detail: "HTTP \(code)")
			}
		} catch {
			let nsError = error as NSError
			logger.error("自检", "清单拉取失败: \(error.localizedDescription)（域 \(nsError.domain) 码 \(nsError.code)）")

			// 中文诊断建议
			if nsError.domain == NSURLErrorDomain {
				switch nsError.code {
				case NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed:
					logger.error("自检", "诊断：TLS 证书不受信任——请确认已连接 Wi-Fi，并在设置中检查安装服务证书")
				case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
					logger.error("自检", "诊断：无法连接本机服务器——端口 \(port) 可能被系统拒绝。请尝试切换安装方式或重启 App")
				case NSURLErrorTimedOut:
					logger.error("自检", "诊断：连接超时——本机环回请求超时极不正常，请切换安装通道")
				default:
					break
				}
			}
			return SelfCheckResult(ok: false, detail: error.localizedDescription)
		}
	}
}

/// 跳过 TLS 评估（仅用于本机环回自检）
private final class InsecureSkipDelegate: NSObject, URLSessionDelegate {
	func urlSession(
		_ session: URLSession,
		didReceive challenge: URLAuthenticationChallenge,
		completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
	) {
		if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
		   let trust = challenge.protectionSpace.serverTrust {
			completionHandler(.useCredential, URLCredential(trust: trust))
		} else {
			completionHandler(.performDefaultHandling, nil)
		}
	}
}
