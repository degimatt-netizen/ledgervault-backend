import SwiftUI

// MARK: - Chain Definition

private struct Chain: Identifiable, Hashable {
    let id:     String   // query param value
    let name:   String
    let symbol: String
    let icon:   String
    let color:  Color
}

private let chains: [Chain] = [
    Chain(id: "eth",   name: "Ethereum",  symbol: "ETH",  icon: "e.circle.fill",        color: Color(red:0.39,green:0.51,blue:0.93)),
    Chain(id: "btc",   name: "Bitcoin",   symbol: "BTC",  icon: "bitcoinsign.circle.fill", color: Color(red:0.97,green:0.60,blue:0.10)),
    Chain(id: "sol",   name: "Solana",    symbol: "SOL",  icon: "s.circle.fill",        color: Color(red:0.55,green:0.26,blue:0.96)),
    Chain(id: "bnb",   name: "BNB Chain", symbol: "BNB",  icon: "b.circle.fill",        color: Color(red:0.96,green:0.74,blue:0.10)),
    Chain(id: "matic", name: "Polygon",   symbol: "MATIC",icon: "p.circle.fill",        color: Color(red:0.54,green:0.17,blue:0.89)),
    Chain(id: "arb",   name: "Arbitrum",  symbol: "ETH",  icon: "a.circle.fill",        color: Color(red:0.16,green:0.55,blue:0.85)),
    Chain(id: "avax",  name: "Avalanche", symbol: "AVAX", icon: "a.circle.fill",        color: Color(red:0.93,green:0.15,blue:0.22)),
    Chain(id: "trx",   name: "Tron",      symbol: "TRX",  icon: "t.circle.fill",        color: Color(red:0.88,green:0.15,blue:0.15)),
]

// MARK: - View

struct WalletAddressScanView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedChain: Chain = chains[0]
    @State private var address: String = ""
    @State private var isScanning = false
    @State private var result: APIService.WalletScanResult? = nil
    @State private var errorMessage: String? = nil
    @State private var showAddSheet = false

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespaces) }
    private var canScan: Bool { trimmedAddress.count > 10 && !isScanning }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // ── Header icon ──────────────────────────────────────
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(LinearGradient(
                                colors: [.purple, Color(red:0.54,green:0.17,blue:0.89)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 72, height: 72)
                        Image(systemName: "cube.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 8)

                    Text("RPC Address Scan")
                        .font(.title2.bold())
                    Text("Enter any on-chain address to see the live balance — no sign-in required.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    // ── Chain picker ──────────────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Blockchain")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(chains) { chain in
                                    ChainChip(chain: chain, isSelected: selectedChain == chain) {
                                        selectedChain = chain
                                        result = nil
                                        errorMessage = nil
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal)

                    // ── Address input ─────────────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Wallet Address")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        HStack(spacing: 0) {
                            TextField("0x… or bc1… or address", text: $address)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(.vertical, 14)
                                .padding(.leading, 14)
                                .onChange(of: address) { _, _ in
                                    result = nil
                                    errorMessage = nil
                                }

                            if !address.isEmpty {
                                Button { address = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.trailing, 10)
                            }

                            Button {
                                if let str = UIPasteboard.general.string {
                                    address = str.trimmingCharacters(in: .whitespaces)
                                }
                            } label: {
                                Text("Paste")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background(Color(.secondarySystemFill))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .padding(.trailing, 10)
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)

                    // ── Scan button ───────────────────────────────────────
                    Button {
                        Task { await scan() }
                    } label: {
                        Group {
                            if isScanning {
                                HStack(spacing: 8) {
                                    ProgressView().tint(.white)
                                    Text("Scanning…")
                                }
                            } else {
                                Label("Scan Balance", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canScan ? Color.purple : Color(.systemFill))
                        .foregroundStyle(canScan ? .white : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!canScan)
                    .padding(.horizontal)

                    // ── Error ─────────────────────────────────────────────
                    if let err = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(err)
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal)
                    }

                    // ── Result card ───────────────────────────────────────
                    if let res = result {
                        ScanResultCard(result: res, chain: selectedChain) {
                            showAddSheet = true
                        }
                        .padding(.horizontal)
                    }

                    Spacer(minLength: 40)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                if let res = result {
                    AddWalletToPortfolioView(result: res)
                }
            }
        }
    }

    // MARK: - Scan

    private func scan() async {
        guard canScan else { return }
        isScanning = true
        result = nil
        errorMessage = nil
        do {
            let r = try await APIService.shared.scanWalletAddress(address: trimmedAddress, chain: selectedChain.id)
            result = r
        } catch {
            errorMessage = error.localizedDescription
        }
        isScanning = false
    }
}

// MARK: - ChainChip

private struct ChainChip: View {
    let chain: Chain
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: chain.icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(chain.name)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? chain.color : Color(.secondarySystemFill))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ScanResultCard

private struct ScanResultCard: View {
    let result: APIService.WalletScanResult
    let chain: Chain
    let onAdd: () -> Void

    private var balanceText: String {
        let bal = result.balance
        if bal < 0.000001 { return "\(bal) \(result.symbol)" }
        let formatted = bal >= 1
            ? String(format: "%.6g", bal)
            : String(format: "%.8f", bal).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return "\(formatted) \(result.symbol)"
    }

    private var usdText: String? {
        guard let usd = result.usd_value else { return nil }
        return usd < 0.01
            ? String(format: "$%.6f", usd)
            : String(format: "$%.2f", usd)
    }

    private var shortAddress: String {
        let a = result.address
        guard a.count > 12 else { return a }
        return "\(a.prefix(6))…\(a.suffix(4))"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Chain + address header
            HStack {
                ZStack {
                    Circle()
                        .fill(chain.color.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: chain.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(chain.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(chain.name)
                        .font(.subheadline.weight(.semibold))
                    Text(shortAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fontDesign(.monospaced)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            }
            .padding()

            Divider()

            // Balance
            VStack(spacing: 4) {
                Text(balanceText)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                if let usd = usdText {
                    Text(usd)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)

            Divider()

            // Add button
            Button(action: onAdd) {
                Label("Add to Portfolio", systemImage: "plus.circle.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(chain.color)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}

// MARK: - AddWalletToPortfolioView

struct AddWalletToPortfolioView: View {
    @Environment(\.dismiss) private var dismiss
    let result: APIService.WalletScanResult

    @State private var accountName: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String? = nil

    private var chainLabel: String {
        chains.first { $0.id == result.chain }?.name ?? result.chain.uppercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Chain")
                        Spacer()
                        Text(chainLabel).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Address")
                        Spacer()
                        Text(result.address.prefix(10) + "…")
                            .foregroundStyle(.secondary)
                            .fontDesign(.monospaced)
                            .font(.caption)
                    }
                    HStack {
                        Text("Balance")
                        Spacer()
                        Text("\(result.balance) \(result.symbol)")
                            .foregroundStyle(.secondary)
                    }
                } header: { Text("Wallet Details") }

                Section {
                    TextField("e.g. My ETH Wallet", text: $accountName)
                } header: { Text("Account Name") }

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add to Portfolio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(accountName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
    }

    private func save() async {
        let name = accountName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        do {
            // Create a crypto_wallet account
            _ = try await APIService.shared.createAccount(
                name: name,
                accountType: "crypto_wallet",
                baseCurrency: result.symbol
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
