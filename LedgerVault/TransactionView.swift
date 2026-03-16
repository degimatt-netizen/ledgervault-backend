// TransactionsView.swift
import SwiftUI

struct TransactionsView: View {
    @State private var transactions: [APIService.TransactionEvent] = []
    @State private var showAdd = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                List {
                    ForEach(transactions, id: \.id) { tx in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(tx.description ?? "No description")
                                    .font(.headline)
                                Text(tx.date)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Text("—")
                                .foregroundColor(.secondary)
                        }
                    }
                    .onDelete { indexSet in
                        Task { await deleteTransactions(at: indexSet) }
                    }
                }
                
                // Floating + button like Buddy
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            showAdd = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.blue)
                                .shadow(radius: 10)
                        }
                        .padding(.bottom, 30)
                        .padding(.trailing, 20)
                    }
                }
            }
            .navigationTitle("Transactions")
            .task { await load() }
            .sheet(isPresented: $showAdd) {
                AddTransactionView { Task { await load() } }
            }
            .refreshable { await load() }
        }
    }

    private func load() async {
        do {
            transactions = try await APIService.shared.fetchTransactionEvents()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTransactions(at offsets: IndexSet) async {
        for index in offsets {
            let tx = transactions[index]
            try? await APIService.shared.deleteTransactionEvent(id: tx.id)
        }
        await load()
    }
}
