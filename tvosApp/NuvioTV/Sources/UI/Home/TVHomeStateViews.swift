import SwiftUI
import Foundation
import UIKit
import ImageIO
import OSLog

struct SimklHomeLoadingDebugReport: View {
    let report: String

    var body: some View {
        VStack(spacing: 12) {
            Text("SIMKL DEBUG REPORT")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.yellow)

            ScrollView {
                Text(report)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.86))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 250)
            .padding(16)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))

            Text("Read or screenshot this report and send it to the developer.")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white.opacity(0.66))
        }
        .padding(22)
        .background(Color.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.yellow.opacity(0.45), lineWidth: 1)
        }
    }
}

struct TVReauthBannerView: View {
    let onSignIn: () -> Void
    var onDismiss: (() -> Void)? = nil
    @FocusState private var isButtonFocused: Bool
    @FocusState private var isDismissFocused: Bool

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color(red: 1.0, green: 0.72, blue: 0.2).opacity(0.22))
                    .frame(width: 46, height: 46)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.2))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("reauth_banner_title", fallback: "Account Sync Paused"))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                Text(L10n.string(
                    "reauth_banner_subtitle",
                    fallback: "Your Nuvio session expired. Sign in to resume syncing your library, add-ons, and watch progress."
                ))
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(2)
            }

            Spacer(minLength: 16)

            Button(action: onSignIn) {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode")
                    Text(L10n.string("tvos_account_sign_in", fallback: "Sign In"))
                }
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isButtonFocused ? .black : .white)
                .padding(.horizontal, 22)
                .frame(height: 48)
                .loginGlassCapsule(highlighted: isButtonFocused, prominent: true)
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($isButtonFocused)
            .focusEffectDisabledIfAvailable()
            .scaleEffect(isButtonFocused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: isButtonFocused)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(isDismissFocused ? .black : .white.opacity(0.75))
                        .frame(width: 44, height: 44)
                        .loginGlassCapsule(highlighted: isDismissFocused)
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($isDismissFocused)
                .focusEffectDisabledIfAvailable()
                .scaleEffect(isDismissFocused ? 1.05 : 1)
                .animation(.easeOut(duration: 0.12), value: isDismissFocused)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 1.0, green: 0.72, blue: 0.2).opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(red: 1.0, green: 0.72, blue: 0.2).opacity(0.32), lineWidth: 1.2)
                )
        )
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

struct TVLoadingView: View {
    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(SettingsAccent.color(for: theme))
            .scaleEffect(1.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable(true)
    }
}

struct TVErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Catalog failed")
                .font(.largeTitle.bold())
            Text(message)
                .font(.title3)
                .foregroundColor(.white.opacity(0.68))
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .foregroundColor(.white)
        .padding(.leading, TVLayout.contentLeading)
        .frame(maxWidth: .infinity, minHeight: 560, alignment: .leading)
        .focusable(true)
    }
}
