//
//  ServerInstaller+Network.swift
//  geekIpa
//
//  本地网络与资源路径工具。
//  说明：原先包含 Vapor + NIOSSL 的 TLS 服务器装配，现改为自研 LocalHTTPServer
//  （Network.framework），本文件只保留纯工具方法。
//

import Foundation
import Darwin

// MARK: - Class extension: 网络与资源
extension ServerInstaller {

	/// 服务器对外使用的主机名：优先局域网地址，取不到则回环
	func sni() -> String {
		let localhost = "127.0.0.1"
		return !getIPFix() ? (Self.getLocalAddress() ?? localhost) : localhost
	}
}

extension ServerInstaller {
	/// 取局域网（en0）或蜂窝（pdp_ip0）的 IPv4 地址
	static func getLocalAddress() -> String? {
		var address: String?
		var ifaddr: UnsafeMutablePointer<ifaddrs>?

		if getifaddrs(&ifaddr) == 0 {
			var ptr = ifaddr
			while ptr != nil {
				let interface = ptr!.pointee
				let addrFamily = interface.ifa_addr.pointee.sa_family

				if addrFamily == UInt8(AF_INET) {
					let name = String(cString: interface.ifa_name)
					if name == "en0" || name == "pdp_ip0" {
						var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
						if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
									   &hostname, socklen_t(hostname.count),
									   nil, socklen_t(0), NI_NUMERICHOST) == 0 {
							address = String(cString: hostname)
						}
					}
				}
				ptr = ptr!.pointee.ifa_next
			}
			freeifaddrs(ifaddr)
		}

		return address
	}
}
