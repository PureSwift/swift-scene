import Testing
@testable import SceneCore

@Suite struct ComponentStorageTests {

    @Test func insertRemoveKeepsDensePacking() {
        var storage = ComponentStorage<String>()
        let a = EntityID(index: 0, generation: 0), b = EntityID(index: 5, generation: 0), c = EntityID(index: 2, generation: 0)
        storage.insert("a", for: a)
        storage.insert("b", for: b)
        storage.insert("c", for: c)
        #expect(storage.count == 3)
        #expect(storage.remove(a) == "a")
        #expect(storage.count == 2)
        #expect(storage[b] == "b")
        #expect(storage[c] == "c")
        #expect(storage[a] == nil)
        #expect(Set(storage.map(\.component)) == ["b", "c"])
    }

    @Test func staleGenerationMisses() {
        var storage = ComponentStorage<Int>()
        storage.insert(1, for: EntityID(index: 3, generation: 0))
        #expect(storage[EntityID(index: 3, generation: 1)] == nil)
        #expect(!storage.contains(EntityID(index: 3, generation: 1)))
    }

    @Test func modifiesInPlace() {
        var storage = ComponentStorage<Int>()
        let e = EntityID(index: 0, generation: 0)
        storage[e] = 1
        storage.modify(e) { $0 += 41 }
        #expect(storage[e] == 42)
    }
}

@Suite struct EntityStoreTests {

    struct Health: Equatable { var value: Int }

    @Test func destroyedEntitiesStayDead() {
        let store = EntityStore()
        let a = store.createEntity()
        store[Health.self, a] = Health(value: 10)
        store.destroy(a)
        #expect(!store.isAlive(a))
        #expect(store[Health.self, a] == nil)
        // The slot is reused with a new generation.
        let b = store.createEntity()
        #expect(b.index == a.index)
        #expect(b.generation != a.generation)
        #expect(store[Health.self, b] == nil)
        store[Health.self, a] = Health(value: 1)
        #expect(store[Health.self, b] == nil)
        #expect(store.entityCount == 1)
    }

    @Test func transferMovesComponents() {
        let source = EntityStore(), destination = EntityStore()
        let e = source.createEntity()
        source[Health.self, e] = Health(value: 7)
        source[LocalTransform.self, e] = LocalTransform(transform: Transform(translation: SIMD3(1, 2, 3)))
        let moved = source.transfer(e, to: destination)
        #expect(!source.isAlive(e))
        #expect(destination[Health.self, moved] == Health(value: 7))
        #expect(destination[LocalTransform.self, moved]?.transform.translation == SIMD3(1, 2, 3))
    }

    @Test func worldMatrixWalksParents() {
        let store = EntityStore()
        let parent = store.createEntity(), child = store.createEntity()
        store[LocalTransform.self, parent] = LocalTransform(transform: Transform(scale: SIMD3(repeating: 2), translation: SIMD3(10, 0, 0)))
        store[LocalTransform.self, child] = LocalTransform(transform: Transform(translation: SIMD3(1, 0, 0)))
        store[Parent.self, child] = Parent(parent)
        #expect(store.worldMatrix(of: child).translation == SIMD3(12, 0, 0))
    }
}

@Suite struct MeshBufferTests {

    @Test func boundsAndInterleaving() {
        let mesh = MeshBuffer(
            vertexCount: 3,
            streams: [
                VertexStream(semantic: .position, vectors: [SIMD3<Float>(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 2, 0)]),
                VertexStream(semantic: .textureCoordinate(0), vectors: [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(0, 1)]),
            ],
            indices: IndexBuffer([0, 1, 2]),
            submeshes: [Submesh(range: 0..<3, materialIndex: 0)]
        )
        #expect(mesh.bounds == BoundingBox(min: .zero, max: SIMD3(1, 2, 0)))
        let interleaved = mesh.interleaved()
        #expect(interleaved.stride == 5)
        #expect(Array(interleaved.data[5..<10]) == [1, 0, 0, 1, 0])
        #expect(mesh.triangles(in: mesh.submeshes[0]) == [SIMD3(0, 1, 2)])
    }

    @Test func stripAlternatesWinding() {
        let mesh = MeshBuffer(
            vertexCount: 4,
            streams: [VertexStream(semantic: .position, componentCount: 3, data: [Float](repeating: 0, count: 12))],
            submeshes: [Submesh(primitive: .triangleStrip, range: 0..<4, materialIndex: 0)]
        )
        #expect(mesh.triangles(in: mesh.submeshes[0]) == [SIMD3(0, 1, 2), SIMD3(1, 3, 2)])
    }

    @Test func immediateDrawsEverySubmesh() {
        var buffer = RecordedCommandBuffer(target: RenderTargetDescriptor(width: 1, height: 1))
        let mesh = MeshBuffer(
            vertexCount: 6,
            streams: [VertexStream(semantic: .position, componentCount: 3, data: [Float](repeating: 0, count: 18))],
            submeshes: [Submesh(range: 0..<3, materialIndex: 0), Submesh(range: 3..<6, materialIndex: 1)]
        )
        let red = MaterialDescriptor.unlit(color: SIMD4(1, 0, 0, 1))
        buffer.drawImmediate(mesh, materials: [red], transform: .identity)
        #expect(buffer.drawCalls.count == 2)
        #expect(buffer.drawCalls.allSatisfy { $0.meshKey == nil && $0.material == red })
    }
}
