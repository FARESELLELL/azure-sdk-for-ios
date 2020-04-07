// --------------------------------------------------------------------------
//
// Copyright (c) Microsoft Corporation. All rights reserved.
//
// The MIT License (MIT)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the ""Software""), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
//
// --------------------------------------------------------------------------

import AzureCore
import CoreData

internal final class URLSessionTransferManager: NSObject, TransferManager, URLSessionTaskDelegate {
    // MARK: Type Alias

    public typealias TransferManagerType = URLSessionTransferManager

    // MARK: Properties

    weak var delegate: TransferDelegate?

    var logger: ClientLogger

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.azuresdk.transfermanager")
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    lazy var reachability: ReachabilityManager? = {
        var manager = ReachabilityManager()
        manager?.registerListener { status in
            switch status {
            case .notReachable:
                self.pauseAll()
            case .reachable(.ethernetOrWiFi), .reachable(.wwan):
                self.operationQueue.clear()
                self.resumeAll()
            default:
                break
            }
        }
        return manager
    }()

    var operationQueue: ResumableOperationQueue

    var transfers: [Transfer]

    var count: Int {
        return transfers.count
    }

    var persistentContainer: NSPersistentContainer? = {
        guard let bundle = Bundle(identifier: "com.azure.storage.AzureStorageBlob") else { return nil }
        guard let url = bundle.url(forResource: "AzureStorage", withExtension: "momd") else { return nil }
        guard let model = NSManagedObjectModel(contentsOf: url) else { return nil }
        let container = NSPersistentContainer(name: "AzureSDKTransferManager", managedObjectModel: model)
        container.loadPersistentStores(completionHandler: { _, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })
        return container
    }()

    // MARK: Initializers

    private override init() {
        self.operationQueue = ResumableOperationQueue(name: "TransferQueue", delegate: nil, removeOnCompletion: true)
        self.transfers = [Transfer]()
        self.logger = ClientLoggers.none

        super.init()
        operationQueue.delegate = self
        operationQueue.maxConcurrentOperationCount = 4
    }

    // TODO: This will interfere with trying to use multiple BlobClients simultaneously. Find an alternate
    // solution such that the minimal set (the NSPersistentContainer) is shared.
    public static var shared: URLSessionTransferManager = {
        let manager = URLSessionTransferManager()
        manager.loadContext()
        return manager
    }()

    // MARK: TransferManager Methods

    subscript(index: Int) -> Transfer {
        // return the operation from the DataStore
        return transfers[index]
    }

    // MARK: Add Operations

    func add(transfer: Transfer) {
        switch transfer {
        case let transfer as BlockTransfer:
            add(transfer: transfer)
        case let transfer as BlobTransfer:
            add(transfer: transfer)
        default:
            fatalError("Unexpected operation type: \(transfer.self)")
        }
    }

    func add(transfer: BlockTransfer) {
        // Add to DataStore
        transfers.append(transfer)

        // Add to OperationQueue and notify delegate
        let operation = BlockOperation(withTransfer: transfer)
        operationQueue.add(operation)
        self.operation(operation, didChangeState: transfer.state)
    }

    func queueOperations(for transfer: BlobTransfer) {
        let disallowed: [TransferState] = [.complete, .canceled, .failed]
        let resumableOperations: [TransferState] = [.pending, .inProgress]
        guard !disallowed.contains(transfer.state) else { return }
        var operations = [ResumableOperation]()

        switch transfer.transferType {
        case .download:
            let pendingTransfers = transfer.transfers.filter { resumableOperations.contains($0.state) }
            if transfer.initialCallComplete {
                let finalOperation = BlobDownloadFinalOperation(withTransfer: transfer, queue: operationQueue)
                operations.append(finalOperation)
                for blockTransfer in pendingTransfers {
                    let blockOperation = BlockOperation(withTransfer: blockTransfer)
                    finalOperation.addDependency(blockOperation)
                    operations.append(blockOperation)
                }
            } else {
                guard let initialTransfer = pendingTransfers.first else {
                    assertionFailure("Invalid assumption regarding pending transfers.")
                    return
                }
                let initialOperation = BlobDownloadInitialOperation(
                    withTransfer: initialTransfer,
                    queue: operationQueue
                )
                operations.append(initialOperation)
            }
        case .upload:
            let finalOperation = BlobUploadFinalOperation(withTransfer: transfer, queue: operationQueue)
            operations.append(finalOperation)
            let pendingTransfers = transfer.transfers.filter { resumableOperations.contains($0.state) }
            for blockTransfer in pendingTransfers {
                let blockOperation = BlockOperation(withTransfer: blockTransfer)
                finalOperation.addDependency(blockOperation)
                operations.append(blockOperation)
            }
        }
        operationQueue.add(operations)
        self.operations(operations, didChangeState: transfer.state)
    }

    func add(transfer: BlobTransfer) {
        guard let context = persistentContainer?.viewContext else { return }

        // Add to DataStore
        transfers.append(transfer)

        if transfer.transfers.isEmpty, transfer.state == .pending {
            switch transfer.transferType {
            case .download:
                let blockTransfer = BlockTransfer.with(context: context, startRange: 0, endRange: 1, parent: transfer)
                transfer.blocks?.adding(blockTransfer)
            case .upload:
                guard let uploader = transfer.uploader else { return }
                for (range, blockId) in uploader.blockList {
                    let blockTransfer = BlockTransfer
                        .with(
                            context: context,
                            id: blockId,
                            startRange: Int64(range.startIndex),
                            endRange: Int64(range.endIndex),
                            parent: transfer
                        )
                    transfer.blocks?.adding(blockTransfer)
                }
            }
            transfer.totalBlocks = Int64(transfer.transfers.count)
        }
        queueOperations(for: transfer)
    }

    // MARK: Cancel Operations

    func cancelAll() {
        for transfer in transfers {
            cancel(transfer: transfer)
        }
    }

    func cancel(transfer: Transfer) {
        guard let transfer = transfer as? TransferImpl else { return }
        transfer.state = .canceled
        assert(transfer.operation != nil, "Transfer operation unexpectedly nil.")
        if let operation = transfer.operation {
            operationQueue.remove(operation)
        }
        if let blob = transfer as? BlobTransfer {
            for block in blob.transfers {
                cancel(transfer: block)
            }
        }
        operation(transfer.operation, didChangeState: transfer.state)
    }

    // MARK: Remove Operations

    func removeAll() {
        // Wipe the DataStore
        transfers.removeAll()

        // Clear the OperationQueue
        operationQueue.clear()

        // Delete all transfers in CoreData
        guard let context = persistentContainer?.viewContext else { return }
        let multiBlobRequest: NSFetchRequest<MultiBlobTransfer> = MultiBlobTransfer.fetchRequest()
        if let transfers = try? context.fetch(multiBlobRequest) {
            for transfer in transfers {
                context.delete(transfer)
            }
        }
        let blobRequest: NSFetchRequest<BlobTransfer> = BlobTransfer.fetchRequest()
        if let transfers = try? context.fetch(blobRequest) {
            for transfer in transfers {
                context.delete(transfer)
            }
        }
        let blockRequest: NSFetchRequest<BlockTransfer> = BlockTransfer.fetchRequest()
        if let transfers = try? context.fetch(blockRequest) {
            for transfer in transfers {
                context.delete(transfer)
            }
        }
        operations(nil, didChangeState: .deleted)
    }

    func remove(transfer: Transfer) {
        guard let transfer = transfer as? TransferImpl else { return }
        switch transfer {
        case let transfer as BlockTransfer:
            remove(transfer: transfer)
        case let transfer as BlobTransfer:
            remove(transfer: transfer)
        default:
            fatalError("Unrecognized transfer type: \(transfer.self)")
        }
        transfer.state = .deleted
        operation(transfer.operation, didChangeState: transfer.state)
    }

    func remove(transfer: BlockTransfer) {
        if let operation = transfer.operation {
            operationQueue.remove(operation)
        }

        if let index = transfers.firstIndex(where: { $0 === transfer }) {
            transfers.remove(at: index)
        }

        // remove the object from CoreData
        if let context = persistentContainer?.viewContext {
            context.delete(transfer)
        }
    }

    internal func remove(transfer: BlobTransfer) {
        // Cancel the operation and any associated block operations
        if let operation = transfer.operation {
            operationQueue.remove(operation)
            for block in transfer.transfers {
                block.state = .deleted
                if let blockOp = block.operation {
                    operationQueue.remove(blockOp)
                }
            }
        }

        // Remove the blob operation from the transfers list
        if let index = transfers.firstIndex(where: { $0 === transfer }) {
            transfers.remove(at: index)
        }

        // remove the object from CoreData which should cascade and delete any outstanding block transfers
        if let context = persistentContainer?.viewContext {
            context.delete(transfer)
        }
    }

    // MARK: Pause Operations

    func pauseAll() {
        operationQueue.clear()
        for transfer in transfers {
            pause(transfer: transfer)
        }
    }

    func pause(transfer: Transfer) {
        guard let blobTransfer = transfer as? BlobTransfer else {
            assertionFailure("Unsupported transfer type: \(transfer.self)")
            return
        }
        pause(transfer: blobTransfer)
    }

    func pause(transfer: BlobTransfer) {
        guard transfer.state.pauseable else { return }
        transfer.state = .paused

        // Cancel the operation
        if let operation = transfer.operation {
            operationQueue.remove(operation)
        }

        // Pause any pauseable blocks and cancel their operations
        for block in transfer.transfers {
            pause(transfer: block)
        }

        // notify delegate
        operation(transfer.operation, didChangeState: transfer.state)
    }

    func pause(transfer: BlockTransfer) {
        guard transfer.state.pauseable else { return }
        transfer.state = .paused

        // Cancel the operation
        if let operation = transfer.operation {
            operationQueue.remove(operation)
        }

        // notify delegate
        operation(transfer.operation, didChangeState: transfer.state)
    }

    // MARK: Resume Operations

    func resumeAll() {
        for transfer in transfers {
            resume(transfer: transfer)
        }
    }

    func resume(transfer: Transfer) {
        guard let transfer = transfer as? TransferImpl else { return }

        guard reachability?.isReachable ?? false else { return }
        guard transfer.state.resumable else { return }
        transfer.state = .pending
        switch transfer {
        case let transfer as BlockTransfer:
            operationQueue.add(BlockOperation(withTransfer: transfer))
        case let transfer as BlobTransfer:
            for blockTransfer in transfer.transfers where blockTransfer.state.resumable {
                blockTransfer.state = .pending
            }
            reconnectClient(for: transfer)
            if transfer.state == .failed {
                // TODO: Fix the issue that this error is not bubbling up to the client
                operation(transfer.operation, didChangeState: transfer.state)
            }
            queueOperations(for: transfer)
        default:
            assertionFailure("Unrecognized transfer type: \(transfer.self)")
        }
        operation(transfer.operation, didChangeState: transfer.state)
    }

    func reconnectClient(for transfer: BlobTransfer) {
        // early out if a client is already connected
        switch transfer.transferType {
        case .upload:
            guard transfer.uploader == nil else { return }
        case .download:
            guard transfer.downloader == nil else { return }
        }

        // must create one
        guard let client = delegate?.client(forRestorationId: transfer.clientRestorationId) as? StorageBlobClient else {
            transfer.error = AzureError.general("Unable to restore client.")
            logger.error(transfer.error?.localizedDescription)
            transfer.state = .failed
            return
        }
        do {
            switch transfer.transferType {
            case .upload:
                guard let sourceUrl = transfer.source else { return }
                guard let destUrl = transfer.destination else { return }
                let blobProperties = transfer.properties
                let uploadOptions = transfer.uploadOptions
                transfer.uploader = try BlobStreamUploader(
                    client: client,
                    delegate: nil,
                    source: sourceUrl,
                    destination: destUrl,
                    properties: blobProperties,
                    options: uploadOptions
                )
            case .download:
                guard let sourceUrl = transfer.source else { return }
                guard let destUrl = transfer.destination else { return }
                transfer.downloader = try BlobStreamDownloader(
                    client: client,
                    delegate: nil,
                    source: sourceUrl,
                    destination: destUrl,
                    options: transfer.downloadOptions
                )
            }
        } catch {
            logger.error(error.localizedDescription)
            transfer.error = error
            transfer.state = .failed
            return
        }
    }

    // MARK: Core Data Operations

    func loadContext() {
        // Hydrate operationQueue from CoreData
        guard let context = persistentContainer?.viewContext else {
            fatalError("Unable to load persistent container.")
        }
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

        let predicate = NSPredicate(format: "parent = nil")
        let blockRequest: NSFetchRequest<BlockTransfer> = BlockTransfer.fetchRequest()
        blockRequest.predicate = predicate
        if let results = try? context.fetch(blockRequest) {
            for transfer in results {
                transfers.append(transfer)
            }
        }
        let blobRequest: NSFetchRequest<BlobTransfer> = BlobTransfer.fetchRequest()
        blobRequest.predicate = predicate
        if let results = try? context.fetch(blobRequest) {
            for transfer in results {
                transfers.append(transfer)
            }
        }
    }

    func saveContext() {
        DispatchQueue.main.async { [weak self] in
            guard let context = self?.persistentContainer?.viewContext else {
                assert(self?.persistentContainer?.viewContext != nil, "Failed to obtain context.")
                return
            }
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    let nserror = error as NSError
                    let message = nserror.localizedDescription
                    let errorMessage = "Unresolved error \(nserror.code): \(message)"
                    assertionFailure(errorMessage)
                }
            }
        }
    }
}