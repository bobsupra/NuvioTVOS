//
//  HomeViewModel.swift
//  NuvioTV
//
//  Created by Claude Code
//  ViewModel for Home Screen
//

import Foundation
import Combine

class HomeViewModel: ObservableObject {
    @Published var state = HomeUiState()
    
    private let repository: CatalogRepository
    
    init(repository: CatalogRepository = MockCatalogRepository()) {
        self.repository = repository
    }
    
    @MainActor
    func loadData() async {
        state.isLoading = true
        state.error = nil
        
        do {
            // 1. Fetch Catalogs
            let catalogs = try await repository.getHomeCatalogs()
            
            // 2. Process catalogs to fetch items
            var processedCatalogs: [HomeCatalog] = []
            
            for catalog in catalogs {
                // In a real app, we'd batch fetch these or the catalog would contain them
                // For this mock/prototype, we'll fetch metadata for the first few items
                let items: [NuvioMeta]
                if let catalogItems = catalog.items {
                    items = Array(catalogItems.prefix(10))
                } else {
                    var resolvedItems: [NuvioMeta] = []
                    for id in catalog.itemIds.prefix(10) {
                        if let meta = try? await repository.getMetadata(id: id, type: catalog.contentType ?? "movie") {
                            resolvedItems.append(meta)
                        }
                    }
                    items = resolvedItems
                }
                
                processedCatalogs.append(HomeCatalog(
                    id: catalog.id,
                    title: catalog.name,
                    items: items
                ))
            }
            
            state.catalogs = processedCatalogs
            
            // 3. Setup Hero Content (using the first item of the first catalog for now, or random)
            if let firstCatalog = processedCatalogs.first, let firstItem = firstCatalog.items.first {
                state.heroContent = firstItem
            }
            
            // 4. Mock Continue Watching & Watchlist (since we don't have a repo for them yet)
            // We'll just use some items from the catalogs
            if processedCatalogs.count > 1 {
                state.continueWatching = Array(processedCatalogs[1].items.prefix(3))
                state.watchlist = Array(processedCatalogs[0].items.suffix(3))
            }
            
            state.isLoading = false
        } catch {
            state.error = error.localizedDescription
            state.isLoading = false
        }
    }
}

struct HomeUiState {
    var isLoading: Bool = true
    var heroContent: NuvioMeta? = nil
    var continueWatching: [NuvioMeta] = []
    var watchlist: [NuvioMeta] = []
    var catalogs: [HomeCatalog] = []
    var error: String? = nil
}

struct HomeCatalog: Identifiable {
    let id: String
    let title: String
    let items: [NuvioMeta]
}
