import Foundation

/// Service responsable de déclencher régulièrement la récupération des données.
/// Utilise des minuteries (Timer) pour exécuter les actions à intervalles définis ou à des heures précises.
@MainActor class Scheduler: ObservableObject {
    private var timer: Timer?
    private var action: (() -> Void)?

    /// Exécute l'action en garantissant le hop sur le MainActor.
    /// Marquée `nonisolated` pour être appelable depuis les closures Timer non-isolées.
    nonisolated private func runAction() {
        Task { @MainActor in
            guard let action = self.action else { return }
            action()
        }
    }

    /// Annule toute planification en cours.
    func cancel() {
        timer?.invalidate()
        timer = nil
        action = nil
    }

    /// Planifie une action à exécuter toutes les `minutes` minutes.
    /// La première exécution est immédiate.
    func schedule(everyMinutes minutes: Int, action: @escaping () -> Void) {
        schedule(every: minutes, immediate: true, action: action)
    }

    /// Variante configurable : exécution immédiate ou non.
    func schedule(every minutes: Int, immediate: Bool = true, action: @escaping () -> Void) {
        cancel()
        self.action = action
        let interval = TimeInterval(minutes * 60)
        if immediate { runAction() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.runAction()
        }
        // S'assurer que le timer tourne pendant les interactions UI (défilement, etc.)
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Planifie une action à une heure précise **chaque jour** (heure/minute locales).
    /// Gère les changements d'heure (DST) en recalculant chaque jour la prochaine occurrence.
    func schedule(dailyAt hour: Int, minute: Int, action: @escaping () -> Void) {
        cancel()
        self.action = action
        scheduleNextDailyFire(hour: hour, minute: minute)
    }

    /// Calcule et programme la prochaine exécution quotidienne (one-shot), puis se replanifie pour le lendemain.
    private func scheduleNextDailyFire(hour: Int, minute: Int) {
        let now = Date()
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let todayAtTarget = Calendar.current.date(from: comps) ?? now
        let firstFire = (todayAtTarget > now) ? todayAtTarget
                                             : Calendar.current.date(byAdding: .day, value: 1, to: todayAtTarget) ?? now.addingTimeInterval(24*60*60)

        let interval = firstFire.timeIntervalSince(now)
        timer = Timer.scheduledTimer(withTimeInterval: max(1.0, interval), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.runAction()
            // Replanifier pour le prochain jour (recalc pour gérer DST)
            Task { @MainActor in
                self.scheduleNextDailyFire(hour: hour, minute: minute)
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Déclenche immédiatement l'action planifiée (utile pour tests/bouton "Sync now").
    func triggerNow() {
        runAction()
    }
}
