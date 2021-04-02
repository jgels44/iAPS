import Foundation
import LoopKit
import SwiftDate
import Swinject

protocol PumpHistoryObserver {
    func pumpHistoryDidUpdate(_ events: [PumpHistoryEvent])
}

protocol PumpHistoryStorage {
    func storePumpEvents(_ events: [NewPumpEvent])
    func storeJournalCarbs(_ carbs: Int)
    func recent() -> [PumpHistoryEvent]
    func nightscoutTretmentsNotUploaded() -> [NigtscoutTreatment]
}

final class BasePumpHistoryStorage: PumpHistoryStorage, Injectable {
    private let processQueue = DispatchQueue(label: "BasePumpHistoryStorage.processQueue")
    @Injected() private var storage: FileStorage!
    @Injected() private var broadcaster: Broadcaster!

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func storePumpEvents(_ events: [NewPumpEvent]) {
        processQueue.async {
            let eventsToStore = events.flatMap { event -> [PumpHistoryEvent] in
                let id = event.raw.md5String
                switch event.type {
                case .bolus:
                    guard let dose = event.dose else { return [] }
                    let amount = Decimal(string: dose.unitsInDeliverableIncrements.description)
                    let minutes = Int((dose.endDate - dose.startDate).timeInterval / 60)
                    return [PumpHistoryEvent(
                        id: id,
                        type: .bolus,
                        timestamp: event.date,
                        amount: amount,
                        duration: minutes,
                        durationMin: nil,
                        rate: nil,
                        temp: nil,
                        carbInput: nil
                    )]
                case .tempBasal:
                    guard let dose = event.dose else { return [] }
                    let rate = Decimal(string: dose.unitsPerHour.description)
                    let minutes = Int((dose.endDate - dose.startDate).timeInterval / 60)
                    return [
                        PumpHistoryEvent(
                            id: id,
                            type: .tempBasalDuration,
                            timestamp: event.date,
                            amount: nil,
                            duration: nil,
                            durationMin: minutes,
                            rate: nil,
                            temp: nil,
                            carbInput: nil
                        ),
                        PumpHistoryEvent(
                            id: "_" + id,
                            type: .tempBasal,
                            timestamp: event.date,
                            amount: nil,
                            duration: nil,
                            durationMin: nil,
                            rate: rate,
                            temp: .absolute,
                            carbInput: nil
                        )
                    ]
                case .suspend:
                    return [
                        PumpHistoryEvent(
                            id: id,
                            type: .pumpSuspend,
                            timestamp: event.date,
                            amount: nil,
                            duration: nil,
                            durationMin: nil,
                            rate: nil,
                            temp: nil,
                            carbInput: nil
                        )
                    ]
                case .resume:
                    return [
                        PumpHistoryEvent(
                            id: id,
                            type: .pumpResume,
                            timestamp: event.date,
                            amount: nil,
                            duration: nil,
                            durationMin: nil,
                            rate: nil,
                            temp: nil,
                            carbInput: nil
                        )
                    ]
                case .rewind:
                    return [
                        PumpHistoryEvent(
                            id: id,
                            type: .rewind,
                            timestamp: event.date,
                            amount: nil,
                            duration: nil,
                            durationMin: nil,
                            rate: nil,
                            temp: nil,
                            carbInput: nil
                        )
                    ]
                case .prime:
                    return [
                        PumpHistoryEvent(
                            id: id,
                            type: .prime,
                            timestamp: event.date,
                            amount: nil,
                            duration: nil,
                            durationMin: nil,
                            rate: nil,
                            temp: nil,
                            carbInput: nil
                        )
                    ]
                default:
                    return []
                }
            }

            self.processNewEvents(eventsToStore)
        }
    }

    func storeJournalCarbs(_ carbs: Int) {
        processQueue.async {
            let eventsToStore = [
                PumpHistoryEvent(
                    id: UUID().uuidString,
                    type: .journalCarbs,
                    timestamp: Date(),
                    amount: nil,
                    duration: nil,
                    durationMin: nil,
                    rate: nil,
                    temp: nil,
                    carbInput: carbs
                )
            ]
            self.processNewEvents(eventsToStore)
        }
    }

    private func processNewEvents(_ events: [PumpHistoryEvent]) {
        dispatchPrecondition(condition: .onQueue(processQueue))
        let file = OpenAPS.Monitor.pumpHistory
        var uniqEvents: [PumpHistoryEvent] = []
        storage.transaction { storage in
            storage.append(events, to: file, uniqBy: \.id)
            uniqEvents = storage.retrieve(file, as: [PumpHistoryEvent].self)?
                .filter { $0.timestamp.addingTimeInterval(1.days.timeInterval) > Date() }
                .sorted { $0.timestamp > $1.timestamp } ?? []
            storage.save(Array(uniqEvents), as: file)
        }
        broadcaster.notify(PumpHistoryObserver.self, on: processQueue) {
            $0.pumpHistoryDidUpdate(uniqEvents)
        }
    }

    func recent() -> [PumpHistoryEvent] {
        storage.retrieve(OpenAPS.Monitor.pumpHistory, as: [PumpHistoryEvent].self)?.reversed() ?? []
    }

    func nightscoutTretmentsNotUploaded() -> [NigtscoutTreatment] {
        let events = recent()
        guard !events.isEmpty else { return [] }

        let temps: [NigtscoutTreatment] = events.reduce([]) { result, event in
            var result = result
            switch event.type {
            case .tempBasal:
                result.append(NigtscoutTreatment(
                    duration: nil,
                    rawDuration: nil,
                    rawRate: event,
                    absolute: event.rate,
                    rate: event.rate,
                    eventType: .nsTempBasal,
                    createdAt: event.timestamp,
                    enteredBy: NigtscoutTreatment.local,
                    bolus: nil,
                    insulin: nil,
                    notes: nil,
                    carbs: nil,
                    targetTop: nil,
                    targetBottom: nil
                ))
            case .tempBasalDuration:
                if var last = result.popLast(), last.eventType == .nsTempBasal, last.createdAt == event.timestamp {
                    last.duration = event.durationMin
                    last.rawDuration = event
                    result.append(last)
                }
            default: break
            }
            return result
        }

        let bolusesAndCarbs = events.compactMap { event -> NigtscoutTreatment? in
            switch event.type {
            case .bolus:
                return NigtscoutTreatment(
                    duration: event.duration,
                    rawDuration: nil,
                    rawRate: nil,
                    absolute: nil,
                    rate: nil,
                    eventType: .bolus,
                    createdAt: event.timestamp,
                    enteredBy: NigtscoutTreatment.local,
                    bolus: event,
                    insulin: event.amount,
                    notes: nil,
                    carbs: nil,
                    targetTop: nil,
                    targetBottom: nil
                )
            case .journalCarbs:
                return NigtscoutTreatment(
                    duration: nil,
                    rawDuration: nil,
                    rawRate: nil,
                    absolute: nil,
                    rate: nil,
                    eventType: .nsCarbCorrection,
                    createdAt: event.timestamp,
                    enteredBy: NigtscoutTreatment.local,
                    bolus: nil,
                    insulin: nil,
                    notes: nil,
                    carbs: Decimal(event.carbInput ?? 0),
                    targetTop: nil,
                    targetBottom: nil
                )
            default: return nil
            }
        }

        let uploaded = storage.retrieve(OpenAPS.Nightscout.uploadedPumphistory, as: [NigtscoutTreatment].self) ?? []

        let treatments = Array(Set([bolusesAndCarbs, temps].flatMap { $0 }).subtracting(Set(uploaded)))

        return treatments.sorted { $0.createdAt! > $1.createdAt! }
    }
}
