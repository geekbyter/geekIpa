//
//  AboutView.swift
//  geekIpa
//
//  关于页：应用名、版本号与作者。
//

import SwiftUI
import NimbleViews

// MARK: - View
struct AboutView: View {
	var body: some View {
		NBList(.localized("About")) {
			Section {
				VStack(spacing: 10) {
					FRAppIconView(size: 72)

					Text(Bundle.main.name)
						.font(.largeTitle)
						.bold()
						.foregroundStyle(Color.accentColor)

					HStack(spacing: 4) {
						Text("版本")
						Text(Bundle.main.version)
					}
					.font(.footnote)
					.foregroundStyle(.secondary)
				}
			}
			.frame(maxWidth: .infinity)
			.listRowBackground(EmptyView())

			Section {
				LabeledContent("作者", value: "geekbyte")
			}
		}
	}
}
