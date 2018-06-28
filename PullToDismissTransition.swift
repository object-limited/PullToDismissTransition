//
//  PullToDismissTransition.swift
//  PullToDismissTransition
//
//  Created by Ben Guild on 2018/06/14.
//  Copyright © 2018年 Ben Guild. All rights reserved.
//

import UIKit

protocol PullToDismissTransitionDelegate: class {
    func canBeginPullToDismiss(on dismissingViewController: UIViewController) -> Bool

    func didBeginPullToDismissAttempt(on dismissingViewController: UIViewController)
    func didCompletePullToDismissAttempt(on dismissingViewController: UIViewController, willDismiss: Bool)
    func didFinishTransition(for dismissingViewController: UIViewController, didDismiss: Bool)
}

extension PullToDismissTransitionDelegate {
    func canBeginPullToDismiss(on dismissingViewController: UIViewController) -> Bool {
        return true
    }

    func didBeginPullToDismissAttempt(on dismissingViewController: UIViewController) {}
    func didCompletePullToDismissAttempt(on dismissingViewController: UIViewController, willDismiss: Bool) {}
    func didFinishTransition(for dismissingViewController: UIViewController, didDismiss: Bool) {}
}

enum PullToDismissTransitionType {
    case slideStatic
    case slideDynamic
    case scale
}

class PullToDismissTransition: UIPercentDrivenInteractiveTransition {
    private struct Metric {
        static let dimmingAlphaTransitionFinishDropDelay: TimeInterval = 0.24
        static let dimmingPeakAlpha: CGFloat = 0.87

        static let minimumTranslationYForDismiss: CGFloat = 87
        static let translationThreshold: CGFloat = 0.35

        static let scalingViewCornerRadius: CGFloat = 12
        static let scalingViewCornerRadiusToggleDuration: TimeInterval = 0.15
        static let scalingPeakScaleDivider: CGFloat = 5

        static let transitionDurationDragSlide: TimeInterval = 0.87
        static let transitionDurationDragScale: TimeInterval = 0.35
        static let transitionReEnableTimeoutAfterScroll: TimeInterval = 0.72

        static let velocityBeginThreshold: CGFloat = 10
        static let velocityFinishThreshold: CGFloat = 1280
    }

    let transitionType: PullToDismissTransitionType
    private(set) weak var viewController: UIViewController?

    private(set) weak var monitoredScrollView: UIScrollView?
    var permitWhenNotAtRootViewController = false

    weak var delegate: PullToDismissTransitionDelegate?

    private weak var dimmingView: UIView?
    private weak var scalingView: UIView?
    private var transitionIsActiveFromTranslationPoint: CGPoint?

    private var didRequestScrollViewBounceDisable = false
    private var longPressGestureIsActive = false
    private var monitoredScrollViewDoesBounce = false
    private var recentScrollIsBlockingTransition = false
    private var scrollInitiateCount: Int = 0
    private var scrollViewObservation: NSKeyValueObservation?
    private var transitionHasEndedAndPanIsInactive = false

    private var mostRecentActiveGestureTranslation: CGPoint?

    var transitionDelegateObservation: NSKeyValueObservation?

    deinit {
        scrollViewObservation?.invalidate()
    }

    init(viewController: UIViewController, transitionType: PullToDismissTransitionType = .slideStatic) {
        self.transitionType = transitionType
        self.viewController = viewController

        super.init()
    }

    func additionalGestureRecognizersForTrigger() -> [UIGestureRecognizer] {
        let panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(didPan))
        panGestureRecognizer.delegate = self

        let longPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(didPress))
        longPressGestureRecognizer.delegate = self
        longPressGestureRecognizer.minimumPressDuration = 0

        return [panGestureRecognizer, longPressGestureRecognizer]
    }

    private func updateBounceLockoutState() {
        guard let monitoredScrollView = monitoredScrollView else { return }
        guard monitoredScrollViewDoesBounce else { return }

        var doesTranslateY = false

        switch transitionType {
        case .slideStatic, .slideDynamic:
            doesTranslateY = true
        case .scale:
            doesTranslateY = false
        }

        let shouldScrollViewBounceBeDisabled =
            (longPressGestureIsActive && mostRecentActiveGestureTranslation == nil) ||
            ((mostRecentActiveGestureTranslation?.y ?? 0) > 0) ||
            (doesTranslateY && transitionHasEndedAndPanIsInactive && monitoredScrollView.contentOffset.y <= 0)

        guard shouldScrollViewBounceBeDisabled != didRequestScrollViewBounceDisable else { return }
        didRequestScrollViewBounceDisable = shouldScrollViewBounceBeDisabled

        guard monitoredScrollView.bounces != !shouldScrollViewBounceBeDisabled else { return }
        monitoredScrollView.bounces = !shouldScrollViewBounceBeDisabled
    }

    func monitorActiveScrollView(scrollView: UIScrollView) {
        if let monitoredScrollView = monitoredScrollView, monitoredScrollViewDoesBounce {
            monitoredScrollView.bounces = true
        }

        scrollViewObservation?.invalidate()

        monitoredScrollView = scrollView

        didRequestScrollViewBounceDisable = false
        monitoredScrollViewDoesBounce = scrollView.bounces
        recentScrollIsBlockingTransition = false

        scrollViewObservation = scrollView.observe(
            \UIScrollView.contentOffset,
            options: [.initial, .new]
        ) { [weak self] scrollView, _ in
            self?.updateBounceLockoutState()

            guard scrollView.contentOffset.y > scrollView.bounds.size.height else { return }

            self?.recentScrollIsBlockingTransition = true
            self?.scrollInitiateCount += 1

            let localCopyOfScrollInitiateCount = self?.scrollInitiateCount

            DispatchQueue.main.asyncAfter(
                deadline: DispatchTime.now() + Metric.transitionReEnableTimeoutAfterScroll
            ) {
                guard self?.monitoredScrollView === scrollView else { return }
                guard self?.scrollInitiateCount == localCopyOfScrollInitiateCount else { return }

                self?.recentScrollIsBlockingTransition = false
            }
        }
    }

    private func isAtRootViewController() -> Bool {
        guard let navigationController = (viewController as? UINavigationController)
            ?? viewController?.navigationController else { return true }

        return (navigationController.viewControllers.count <= 1)
    }

    private func canBeginPullToDismiss(
        velocity: CGPoint = .zero,
        on viewController: UIViewController
    ) -> Bool {
        return !recentScrollIsBlockingTransition &&
            velocity.y > Metric.velocityBeginThreshold &&
            velocity.y > fabs(velocity.x) &&
            (permitWhenNotAtRootViewController || isAtRootViewController()) &&
            (monitoredScrollView?.contentOffset.y ?? 0) <= 0 &&
            (delegate?.canBeginPullToDismiss(on: viewController) ?? true)
    }

    private func stopPullToDismiss(on viewController: UIViewController, finished: Bool) {
        if finished {
            finish()
        } else {
            cancel()
        }

        guard transitionIsActiveFromTranslationPoint != nil else { return }
        transitionIsActiveFromTranslationPoint = nil

        delegate?.didCompletePullToDismissAttempt(on: viewController, willDismiss: finished)
    }

    private func handlePan(from panGestureRecognizer: UIPanGestureRecognizer, on view: UIView) {
        guard let viewController = viewController else { return }

        let translation = panGestureRecognizer.translation(in: view)
        let velocity = panGestureRecognizer.velocity(in: view)

        switch panGestureRecognizer.state {
        case .began, .changed:
            mostRecentActiveGestureTranslation = translation
            transitionHasEndedAndPanIsInactive = false

            if let transitionIsActiveFromTranslationPoint = transitionIsActiveFromTranslationPoint {
                let progress = min(1, max(
                    0,
                    (translation.y - transitionIsActiveFromTranslationPoint.y) / max(1, view.bounds.size.height)
                ))

                if progress == 0 {
                    stopPullToDismiss(on: viewController, finished: false)
                    break
                }

                update(progress)
            } else if canBeginPullToDismiss(velocity: velocity, on: viewController) {
                transitionIsActiveFromTranslationPoint = translation

                if let monitoredScrollView = monitoredScrollView, monitoredScrollView.isScrollEnabled {
                    monitoredScrollView.contentOffset = CGPoint(
                        x: monitoredScrollView.contentOffset.x,
                        y: 0
                    )
                }

                viewController.dismiss(animated: true) { [weak self] in
                    self?.delegate?.didFinishTransition(
                        for: viewController,
                        didDismiss: (viewController.presentingViewController == nil)
                    )
                }

                delegate?.didBeginPullToDismissAttempt(on: viewController)
            }
        case .cancelled, .ended:
            if transitionIsActiveFromTranslationPoint != nil {
                transitionHasEndedAndPanIsInactive = true
            }

            mostRecentActiveGestureTranslation = nil

            stopPullToDismiss(on: viewController, finished: panGestureRecognizer.state != .cancelled && (
                (percentComplete >= Metric.translationThreshold && velocity.y >= 0) ||
                    (
                        velocity.y >= Metric.velocityFinishThreshold &&
                            translation.y >= Metric.minimumTranslationYForDismiss
                    )
            ))
        default:
            break
        }

        updateBounceLockoutState()
    }

    private func handlePress(from longPressGestureRecognizer: UILongPressGestureRecognizer, on view: UIView) {
        guard monitoredScrollViewDoesBounce else { return }

        switch longPressGestureRecognizer.state {
        case .began:
            longPressGestureIsActive = true

        case .cancelled, .ended:
            longPressGestureIsActive = false

        default:
            break
        }

        updateBounceLockoutState()
    }

    @objc private func didPan(sender: Any?) {
        guard let panGestureRecognizer = sender as? UIPanGestureRecognizer else { return }
        guard let view = panGestureRecognizer.view else { return }

        handlePan(from: panGestureRecognizer, on: view)
    }

    @objc private func didPress(sender: Any?) {
        guard let longPressGestureRecognizer = sender as? UILongPressGestureRecognizer else { return }
        guard let view = longPressGestureRecognizer.view else { return }

        handlePress(from: longPressGestureRecognizer, on: view)
    }
}

extension PullToDismissTransition: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }
}

extension PullToDismissTransition: UIViewControllerAnimatedTransitioning {
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        switch transitionType {
        case .slideStatic, .slideDynamic:
            return Metric.transitionDurationDragSlide
        case .scale:
            return Metric.transitionDurationDragScale
        }
    }

    private func setupTransitionViewsIfNecessary(
        using transitionContext: UIViewControllerContextTransitioning,
        in viewController: UIViewController
    ) {
        if dimmingView == nil {
            let dimmingView = UIView()
            dimmingView.alpha = Metric.dimmingPeakAlpha
            dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dimmingView.frame = transitionContext.containerView.bounds

            let color: UIColor?

            switch transitionType {
            case .slideStatic, .slideDynamic:
                color = .black
            case .scale:
                color = .white
            }

            dimmingView.backgroundColor = color

            self.dimmingView = dimmingView
            transitionContext.containerView.insertSubview(dimmingView, belowSubview: viewController.view)
        }

        if transitionType != .slideDynamic && scalingView == nil,
            let scalingView = viewController.view.resizableSnapshotView(
                from: viewController.view.bounds,
                afterScreenUpdates: true,
                withCapInsets: .zero
            ) {
            scalingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scalingView.frame = transitionContext.containerView.bounds
            scalingView.transform = .identity

            self.scalingView = scalingView
            transitionContext.containerView.insertSubview(scalingView, aboveSubview: viewController.view)

            viewController.view.isHidden = true

            var shouldRoundCorners = false

            switch transitionType {
            case .slideStatic, .slideDynamic:
                break
            case .scale:
                shouldRoundCorners = true
            }

            if shouldRoundCorners {
                scalingView.layer.masksToBounds = true

                UIViewPropertyAnimator(duration: Metric.scalingViewCornerRadiusToggleDuration, curve: .easeIn) {
                    scalingView.layer.cornerRadius = Metric.scalingViewCornerRadius
                }.startAnimation()
            }
        }
    }

    private func tearDownTransitionViewsAsNecessary(
        using transitionContext: UIViewControllerContextTransitioning,
        for viewController: UIViewController,
        completionHandler: (() -> Void)? = nil
    ) {
        if transitionContext.transitionWasCancelled, let scalingView = scalingView {
            if scalingView.layer.cornerRadius > 0 {
                viewController.view.layer.cornerRadius = scalingView.layer.cornerRadius
                viewController.view.layer.masksToBounds = true

                UIViewPropertyAnimator(duration: Metric.scalingViewCornerRadiusToggleDuration, curve: .easeIn) {
                    viewController.view.layer.cornerRadius = 0
                }.startAnimation()
            }

            viewController.view.isHidden = false

            scalingView.removeFromSuperview()
            self.scalingView = nil
        }

        let completeBlock: (Bool) -> Void = { [weak self] finished -> Void in
            if finished {
                self?.dimmingView?.removeFromSuperview()
                self?.dimmingView = nil
            }

            completionHandler?()
        }

        if dimmingView != nil {
            var holdDimmingView = false

            switch transitionType {
            case .slideStatic, .slideDynamic:
                holdDimmingView = false
            case .scale:
                holdDimmingView = !transitionContext.transitionWasCancelled
            }

            if holdDimmingView {
                UIView.animate(
                    withDuration: Metric.dimmingAlphaTransitionFinishDropDelay,
                    animations: { [weak self] in
                        self?.dimmingView?.alpha = transitionContext.transitionWasCancelled ? 1 : 0
                    },
                    completion: completeBlock
                )

                return
            }
        }

        completeBlock(true)
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let fromVc = transitionContext.viewController(
            forKey: UITransitionContextViewControllerKey.from
        ) else { return }

        setupTransitionViewsIfNecessary(using: transitionContext, in: fromVc)

        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            delay: 0,
            options: .curveEaseOut,
            animations: { [weak self] in
                guard let strongSelf = self else { return }

                switch strongSelf.transitionType {
                case .slideStatic, .slideDynamic:
                    guard let slideView = (
                        strongSelf.transitionType == .slideDynamic
                            ?
                            fromVc.view
                            :
                            strongSelf.scalingView
                    ) else { break }

                    slideView.frame = slideView.frame.offsetBy(
                        dx: 0,
                        dy: slideView.window?.bounds.height ?? 0
                    )

                    strongSelf.dimmingView?.alpha = 0
                case .scale:
                    guard let scalingView = strongSelf.scalingView else { break }
                    scalingView.alpha = 0
                    scalingView.frame = scalingView.frame.insetBy(
                        dx: scalingView.frame.width / Metric.scalingPeakScaleDivider,
                        dy: scalingView.frame.height / Metric.scalingPeakScaleDivider
                    )
                }
            },
            completion: { [weak self] _ in
                self?.tearDownTransitionViewsAsNecessary(
                    using: transitionContext,
                    for: fromVc,
                    completionHandler: {
                        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                    }
                )
            }
        )
    }
}