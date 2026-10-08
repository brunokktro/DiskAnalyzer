import Foundation

/// Criteria shared by the hierarchy listing, the treemap and the Largest Items list.
public struct FileFilter: Sendable, Hashable {
    public enum Age: String, CaseIterable, Sendable, Identifiable {
        case any, olderThanMonth, olderThanSixMonths, olderThanYear, newerThanWeek, newerThanMonth
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .any: "Any date"
            case .olderThanMonth: "Not modified in 1 month"
            case .olderThanSixMonths: "Not modified in 6 months"
            case .olderThanYear: "Not modified in 1 year"
            case .newerThanWeek: "Modified in the last week"
            case .newerThanMonth: "Modified in the last month"
            }
        }

        func matches(_ time: Double, now: Date) -> Bool {
            let age = now.timeIntervalSince1970 - time
            let day = 86_400.0
            switch self {
            case .any: return true
            case .olderThanMonth: return age >= 30 * day
            case .olderThanSixMonths: return age >= 182 * day
            case .olderThanYear: return age >= 365 * day
            case .newerThanWeek: return age < 7 * day
            case .newerThanMonth: return age < 30 * day
            }
        }
    }

    /// Case- and diacritic-insensitive substring of the name. Empty matches everything.
    public var nameContains: String
    /// Minimum size in the active metric.
    public var minimumSize: Int64
    /// Empty means every category.
    public var categories: Set<FileCategory>
    public var age: Age
    public var includesHidden: Bool

    public init(
        nameContains: String = "",
        minimumSize: Int64 = 0,
        categories: Set<FileCategory> = [],
        age: Age = .any,
        includesHidden: Bool = true
    ) {
        self.nameContains = nameContains
        self.minimumSize = minimumSize
        self.categories = categories
        self.age = age
        self.includesHidden = includesHidden
    }

    public static let none = FileFilter()

    public var isActive: Bool { self != .none }

    /// Whether a single node passes the item-level criteria.
    public func matches(_ node: FileNode, metric: SizeMetric, now: Date = Date()) -> Bool {
        if !includesHidden, node.flags.contains(.hidden) { return false }
        if node.size(metric) < minimumSize { return false }
        if !categories.isEmpty, !categories.contains(FileCategory.classify(node)) { return false }
        if !age.matches(node.modificationTime, now: now) { return false }
        if !nameContains.isEmpty,
           node.name.range(of: nameContains, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }
        return true
    }
}

public struct LargestItemsQuery: Sendable, Hashable {
    public var limit: Int
    public var metric: SizeMetric
    public var filter: FileFilter
    /// Packages (`.app`, `.photoslibrary`...) are listed as one item instead of exposing their contents.
    public var treatsPackagesAsItems: Bool

    public init(limit: Int = 200, metric: SizeMetric = .allocated, filter: FileFilter = .none, treatsPackagesAsItems: Bool = true) {
        self.limit = limit
        self.metric = metric
        self.filter = filter
        self.treatsPackagesAsItems = treatsPackagesAsItems
    }
}

public enum TreeQueries {
    /// Largest files (and optionally packages) below `start`, biggest first.
    /// Hard-link duplicates are skipped so the list never double-counts an inode.
    /// O(n log k) with a bounded min-heap.
    public static func largestItems(in tree: FileTree, under start: NodeID = FileTree.rootID, query: LargestItemsQuery, now: Date = Date()) -> [NodeID] {
        guard query.limit > 0 else { return [] }
        var heap = BoundedMinHeap(capacity: query.limit) { (lhs: (Int64, NodeID), rhs: (Int64, NodeID)) in
            lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
        }
        tree.walkDescendants(of: start) { id, node in
            if !query.filter.includesHidden, node.flags.contains(.hidden) { return false }
            let isPackageItem = query.treatsPackagesAsItems && node.isPackage
            let isCandidate = (node.kind == .file || isPackageItem) && !node.flags.contains(.hardLinkDuplicate)
            if isCandidate, query.filter.matches(node, metric: query.metric, now: now) {
                heap.insert((node.size(query.metric), id))
            }
            return !isPackageItem
        }
        return heap.sortedDescending().map(\.1)
    }

    /// Children of `parent` that pass the filter. A directory passes when itself or
    /// any descendant passes, so filtering never hides the path to a match.
    public static func filteredChildren(in tree: FileTree, of parent: NodeID, metric: SizeMetric, filter: FileFilter, now: Date = Date()) -> [NodeID] {
        let children = tree.sortedChildren(of: parent, by: metric)
        guard filter.isActive else { return children }
        return children.filter { subtreeMatches(tree, $0, metric: metric, filter: filter, now: now) }
    }

    public static func subtreeMatches(_ tree: FileTree, _ id: NodeID, metric: SizeMetric, filter: FileFilter, now: Date = Date()) -> Bool {
        let node = tree[id]
        if !filter.includesHidden, node.flags.contains(.hidden) { return false }
        if filter.matches(node, metric: metric, now: now) { return true }
        guard node.isDirectory, node.size(metric) >= filter.minimumSize else { return false }
        var found = false
        tree.walkDescendants(of: id) { _, child in
            if found { return false }
            if !filter.includesHidden, child.flags.contains(.hidden) { return false }
            if filter.matches(child, metric: metric, now: now) { found = true; return false }
            return child.size(metric) >= filter.minimumSize
        }
        return found
    }

    /// Allocated and logical bytes per category below `start`, counting files only.
    public static func categoryBreakdown(in tree: FileTree, under start: NodeID = FileTree.rootID) -> [FileCategory: (allocated: Int64, logical: Int64, count: Int)] {
        var result: [FileCategory: (allocated: Int64, logical: Int64, count: Int)] = [:]
        tree.walkDescendants(of: start) { _, node in
            guard node.kind == .file, !node.flags.contains(.hardLinkDuplicate) else { return true }
            let category = FileCategory.classify(node)
            var entry = result[category] ?? (0, 0, 0)
            entry.allocated += node.allocatedSize
            entry.logical += node.logicalSize
            entry.count += 1
            result[category] = entry
            return true
        }
        return result
    }
}

/// Keeps the `capacity` largest elements seen. `less` defines the heap order.
struct BoundedMinHeap<Element> {
    private(set) var storage: [Element] = []
    let capacity: Int
    let less: (Element, Element) -> Bool

    init(capacity: Int, less: @escaping (Element, Element) -> Bool) {
        self.capacity = capacity
        self.less = less
        storage.reserveCapacity(min(capacity, 4_096))
    }

    mutating func insert(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
            siftUp(storage.count - 1)
        } else if let minimum = storage.first, less(minimum, element) {
            storage[0] = element
            siftDown(0)
        }
    }

    func sortedDescending() -> [Element] {
        storage.sorted { less($1, $0) }
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard less(storage[child], storage[parent]) else { return }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1, right = left + 1
            var smallest = parent
            if left < storage.count, less(storage[left], storage[smallest]) { smallest = left }
            if right < storage.count, less(storage[right], storage[smallest]) { smallest = right }
            if smallest == parent { return }
            storage.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
