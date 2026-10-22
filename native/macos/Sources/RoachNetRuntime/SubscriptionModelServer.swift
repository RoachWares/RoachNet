import Foundation

extension NativeModelServer {
    func subscriptionTags() -> [JSON] {
        guard let subscriptions else { return [] }
        return subscriptions.listed().map { item in
            let name = "\(item.provider.rawValue):\(item.model)"
            return [
                "name": JSON(name), "model": JSON(name), "modified_at": JSON(JS.isoNow()), "size": 0, "digest": "",
                "details": [
                    "parent_model": "", "format": "subscription", "family": JSON(item.provider.rawValue),
                    "families": [JSON(item.provider.rawValue)],
                    "parameter_size": "", "quantization_level": "",
                ],
                "remote_host": JSON(item.provider.kind.label),
            ]
        }
    }

    func subscriptionOpenAIModels() -> [JSON] {
        guard let subscriptions else { return [] }
        return subscriptions.listed().map { item in
            [
                "id": JSON("\(item.provider.rawValue):\(item.model)"), "object": "model",
                "created": JSON(Double(Int(Date().timeIntervalSince1970))),
                "owned_by": JSON(item.provider.ownedBy),
            ]
        }
    }

    struct SubscriptionTrace {
        var observation: ObservationHandle
        var ownTrace: TraceHandle?
        var enrichesParent: Bool
    }

    func subscriptionTrace(
        name: String, model: String, provider: SubscriptionModels.Provider, input: JSON, traceparent: String?
    ) -> SubscriptionTrace? {
        guard let tracer else { return nil }
        if let attached = tracer.attach(traceparent: traceparent) {
            let (handle, parent) = attached
            if parent.type == .generation {
                let observation = ObservationHandle(tracer: tracer, traceId: handle.traceId, id: parent.id)
                observation.update { record in
                    if record.model == nil { record.model = model }
                    if record.provider == nil { record.provider = provider.kind.provider }
                }
                return SubscriptionTrace(observation: observation, ownTrace: nil, enrichesParent: true)
            }
            let observation = handle.observation(
                .generation, name, parentId: parent.id, input: input, model: model, provider: provider.kind.provider)
            return SubscriptionTrace(observation: observation, ownTrace: nil, enrichesParent: false)
        }
        guard tracer.settings.traceModelServer,
            let own = tracer.startTrace(kind: "model", name: name, tags: ["model-server", "plan"], input: input)
        else { return nil }
        let observation = own.observation(
            .generation, model, input: input, model: model, provider: provider.kind.provider)
        return SubscriptionTrace(observation: observation, ownTrace: own, enrichesParent: false)
    }
}
