//
//  SettingsView.swift
//  geekIpa
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import NimbleViews
import UIKit
import Darwin
import IDeviceSwift

// MARK: - View
struct SettingsView: View {
	@AppStorage("geekIpa.selectedCert") private var _storedSelectedCert: Int = 0

	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .default
	) private var _certificates: FetchedResults<CertificatePair>

	private var selectedCertificate: CertificatePair? {
		guard
			_storedSelectedCert >= 0,
			_storedSelectedCert < _certificates.count
		else {
			return nil
		}
		return _certificates[_storedSelectedCert]
	}

	// MARK: Body
	var body: some View {
		NBNavigationView("设置") {
			Form {
				Section {
					NavigationLink(destination: AboutView()) {
						Label {
							Text(verbatim: "关于 geekIpa")
						} icon: {
							FRAppIconView(size: 23)
						}
					}
				}

				Section {
					NavigationLink(destination: AppearanceView()) {
						Label("外观", systemImage: "paintbrush")
					}
				} footer: {
					Text("跟随系统 / 浅色 / 深色，以及主色调。")
				}

				Section {
					NavigationLink(destination: AppleIDAccountView()) {
						Label("Apple ID 账号", systemImage: "person.badge.key")
					}
				} header: {
					Text("Apple ID")
				} footer: {
					Text("登录 Apple ID 可生成免费签名证书（7 天有效）。")
				}

				Section {
					NavigationLink(destination: InstallLogFullView()) {
						Label("诊断日志", systemImage: "doc.text.magnifyingglass")
					}
				} footer: {
					Text("签名与安装的完整过程日志，遇到问题时可用于排查。")
				}
			}
		}
	}
}
