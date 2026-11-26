/// An entity: a slot index and the generation of the slot when it was made, so an identifier
/// outliving its entity never names the slot's next occupant.
public struct EntityID: Hashable, Sendable {

    public let index: UInt32

    public let generation: UInt32

    @inlinable
    public init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }
}

extension EntityID: CustomStringConvertible {

    public var description: String { "Entity(\(index)v\(generation))" }
}
