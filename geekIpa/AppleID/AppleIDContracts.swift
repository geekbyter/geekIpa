//
//  AppleIDContracts.swift
//  geekIpa
//
//  模块间契约：AppleID 模块实现，续签/名额模块依赖。
//  该文件由架构统一定义，禁止各模块私自修改签名。
//

import Foundation
import AltSign

/// Apple ID 会话提供者（AppleIDManager 实现）
public protocol AppleIDSessionProviding: AnyObject {
	/// 当前是否已登录
	var isLoggedIn: Bool { get }
	/// 当前登录的 Apple ID 邮箱
	var accountEmail: String? { get }
	/// 获取有效会话（过期则静默刷新；无法刷新时抛出需要重新登录的错误）
	func validSession() async throws -> ALTAppleAPISession
	/// 当前使用的团队（免费个人团队或个人开发者团队）
	func currentTeam() async throws -> ALTTeam
}

/// 描述文件刷新能力（续签模块依赖）
public protocol ProvisioningRefreshing: AnyObject {
	/// 为指定 bundleID 拉取最新描述文件数据（免费证书描述文件 7 天有效）
	func freshProfileData(bundleIdentifier: String, appName: String) async throws -> Data
	/// 当前 Apple ID 开发证书的 p12 数据与密码（证书一年有效，私钥本地生成）
	func currentSigningP12() throws -> (data: Data, password: String)
}

/// 名额管理依赖
public protocol AppIDListing: AnyObject {
	/// 列出该 Apple ID 下所有已注册 App ID 及其描述文件状态
	func listAppIDs() async throws -> [ALTAppID]
	/// 删除描述文件以释放免费名额（3 个上限）
	@discardableResult
	func deleteProfile(for appID: ALTAppID) async throws -> Bool
}

/// 全局服务定位（在 geekIpaApp 启动时装配）
public final class GeekIpaServices {
	public static let shared = GeekIpaServices()
	private init() {}

	public weak var sessionProvider: (any AppleIDSessionProviding)?
	public weak var profileRefresher: (any ProvisioningRefreshing)?
	public weak var appIDLister: (any AppIDListing)?
}
