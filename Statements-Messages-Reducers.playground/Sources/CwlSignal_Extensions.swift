//
//  CwlSignalExtensions.swift
//  CwlSignal
//
//  Created by Matt Gallagher on 2016/08/04.
//  Copyright © 2016 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation

extension SignalSender {
	/// A convenience version of `send` that wraps a value in `Result.success` before sending
	///
	/// - Parameter value: will be wrapped and sent
	/// - Returns: the return value from the underlying `send(result:)` function
	@discardableResult
	public func send(value: ValueType) -> SignalError? {
		return send(result: .success(value))
	}

	/// A convenience version of `send` that wraps an error in `Result.failure` before sending
	///
	/// - Parameter error: will be wrapped and sent
	/// - Returns: the return value from the underlying `send(result:)` function
	@discardableResult
	public func send(error: Error) -> SignalError? {
		return send(result: .failure(error))
	}
	
	/// Sends a `Result.failure(SignalError.closed)`
	///
	/// - Returns: the return value from the underlying `send(result:)` function
	@discardableResult
	public func close() -> SignalError? {
		return send(result: .failure(SignalError.closed))
	}
}

extension Signal {
	/// A version of `generate` that retains the latest `input` so it doesn't automatically close the signal when the input falls out of scope. This enables a generator that never closes (lives until deactivation).
	///
	/// - Parameters:
	///   - context: the `activationChange` will be invoked in this context
	///   - activationChange: receives inputs on activation and nil on each deactivation
	/// - Returns: the constructed `Signal`
	public static func retainedGenerate(context: Exec = .direct, activationChange: @escaping (SignalInput<T>?) -> Void) -> Signal<T> {
		var latestInput: SignalInput<T>? = nil
		return .generate(context: context) { input in
			latestInput = input
			withExtendedLifetime(latestInput) {}
			activationChange(input)
		}
	}

	/// A convenience version of `subscribe` that only invokes the `processor` on `Result.success`
	///
	/// - Parameters:
	///   - context: the execution context where the `processor` will be invoked
	///   - handler: will be invoked with each value received
	/// - Returns: the `SignalEndpoint` created by this function
	public func subscribeValues(context: Exec = .direct, handler: @escaping (ValueType) -> Void) -> SignalEndpoint<ValueType> {
		return subscribe(context: context) { r in
			if case .success(let v) = r {
				handler(v)
			}
		}
	}
	
	/// A convenience version of `subscribeAndKeepAlive` that only invokes the `processor` on `Result.success`
	///
	/// NOTE: this subscriber deliberately creates a reference counted loop. If the signal is never closed, it will result in a memory leak. This function should be used only when `self` is guaranteed to close.
	///
	/// - Parameters:
	///   - context: the execution context where the `processor` will be invoked
	///   - handler: will be invoked with each value received and if returns `false`, the endpoint will be cancelled and released
	public func subscribeValuesAndKeepAlive(context: Exec = .direct, handler: @escaping (ValueType) -> Bool) {
		subscribeAndKeepAlive(context: context) { r in
			if case .success(let v) = r {
				return handler(v)
			} else {
				return false
			}
		}
	}
	
	/// Returns a signal that drops an `initial` number of values from the start of the stream and emits the next value and every `count`-th value after that.
	///
	/// - Parameters:
	///   - count: number of values beteen emissions
	///   - initialSkip: number of values before the first emission
	/// - Returns: the strided signal
	public func stride(count: Int, initialSkip: Int = 0) -> Signal<T> {
		return transform(initialState: count - initialSkip - 1) { (state: inout Int, r: Result<T>, n: SignalNext<T>) in
			switch r {
			case .success(let v) where state >= count - 1:
				n.send(value: v)
				state = 0
			case .success:
				state += 1
			case .failure(let e):
				n.send(error: e)
			}
		}
	}
	
	/// A signal transform function that, instead of creating plain values and emitting them to a `SignalNext`, creates entire signals and adds them to a `SignalMergeSet`. The output of the merge set (which contains the merged output from all of the created signals) forms the signal returned from this function.
	///
	/// NOTE: this function is primarily used for implementing various Reactive X operators.
	///
	/// - Parameters:
	///   - closePropagation: whether signals added to the merge set will close the output
	///   - context: the context where the processor will run
	///   - processor: performs work with values from this `Signal` and the `SignalMergeSet` used for output
	/// - Returns: output of the merge set
	public func transformFlatten<U>(closePropagation: SignalClosePropagation = .none, context: Exec = .direct, _ processor: @escaping (T, SignalMergeSet<U>) -> ()) -> Signal<U> {
		return transformFlatten(initialState: (), closePropagation: closePropagation, context: context, { (state: inout (), value: T, mergeSet: SignalMergeSet<U>) in processor(value, mergeSet) })
	}
	
	/// A signal transform function that, instead of creating plain values and emitting them to a `SignalNext`, creates entire signals and adds them to a `SignalMergeSet`. The output of the merge set (which contains the merged output from all of the created signals) forms the signal returned from this function.
	///
	/// NOTE: this function is primarily used for implementing various Reactive X operators.
	///
	/// - Parameters:
	///   - initialState: initial state for the state parameter passed into the processor
	///   - closePropagation: whether signals added to the merge set will close the output
	///   - context: the context where the processor will run
	///   - processor: performs work with values from this `Signal` and the `SignalMergeSet` used for output
	/// - Returns: output of the merge set
	public func transformFlatten<S, U>(initialState: S, closePropagation: SignalClosePropagation = .none, context: Exec = .direct, _ processor: @escaping (inout S, T, SignalMergeSet<U>) -> ()) -> Signal<U> {
		let (mergeSet, result) = Signal<U>.createMergeSet()
		var closeError: Error? = nil
		let outerSignal = transform(initialState: initialState, context: context) { (state: inout S, r: Result<T>, n: SignalNext<U>) in
			switch r {
			case .success(let v): processor(&state, v, mergeSet)
			case .failure(let e):
				closeError = e
				n.send(error: e)
			}
		}
		
		// Keep the merge set alive at least as long as self
		_ = try? mergeSet.add(outerSignal, closePropagation: closePropagation)
		
		return result.transform(initialState: nil) { [weak mergeSet] (onDelete: inout OnDelete?, r: Result<U>, n: SignalNext<U>) in
			if onDelete == nil {
				onDelete = OnDelete {
					closeError = nil
				}
			}
			switch r {
			case .success(let v): n.send(value: v)
			case .failure(SignalError.cancelled):
				// If the `mergeSet` is `nil` at this point, that means that this `.cancelled` comes from the `mergeSet`, not one of its inputs. We'd prefer in that case to emit the `outerSignal`'s `closeError` rather than follow the `shouldPropagateError` logic.
				n.send(error: mergeSet == nil ? (closeError ?? SignalError.cancelled) : SignalError.cancelled)
			case .failure(let e):
				n.send(error: closePropagation.shouldPropagateError(e) ? e : (closeError ?? SignalError.cancelled))
			}
		}
	}

	/// A utility function, used by ReactiveX implementations, that generates "window" durations in single signal from the values in self and a "duration" function that returns duration signals for each value.
	///
	/// - Parameters:
	///   - closePropagation: passed through to the underlying `transformFlatten` call (unlikely to make much different in expected use cases of this function)
	///   - context: the context where `duration` will be invoked
	///   - duration: for each value emitted by `self`, emit a signal
	/// - Returns: a signal of two element tuples
	public func valueDurations<U>(closePropagation: SignalClosePropagation = .none, context: Exec = .direct, duration: @escaping (T) -> Signal<U>) -> Signal<(Int, T?)> {
		return valueDurations(initialState: (), closePropagation: closePropagation, context: context, duration: { (state: inout (), value: T) -> Signal<U> in duration(value) })
	}

	/// A utility function, used by ReactiveX implementations, that generates "window" durations in single signal from the values in self and a "duration" function that returns duration signals for each value.
	///
	/// - Parameters:
	///   - initialState: initial state for the state parameter passed into the processor
	///   - closePropagation: passed through to the underlying `transformFlatten` call (unlikely to make much different in expected use cases of this function)
	///   - context: the context where `duration` will be invoked
	///   - duration: for each value emitted by `self`, emit a signal
	/// - Returns: a signal of two element tuples
	public func valueDurations<U, V>(initialState: V, closePropagation: SignalClosePropagation = .none, context: Exec = .direct, duration: @escaping (inout V, T) -> Signal<U>) -> Signal<(Int, T?)> {
		return transformFlatten(initialState: (index: 0, userState: initialState), closePropagation: closePropagation, context: context) { (state: inout (index: Int, userState: V), v: T, mergeSet: SignalMergeSet<(Int, T?)>) in
			let count = state.index
			let innerSignal = duration(&state.userState, v).transform { (innerResult: Result<U>, innerInput: SignalNext<(Int, T?)>) in
				if case .failure(let e) = innerResult {
					innerInput.send(value: (count, nil))
					innerInput.send(error: e)
				}
			}
			let prefixedInnerSignal = Signal<(Int, T?)>.preclosed(values: [(count, Optional(v))]).combine(second: innerSignal) { (r: EitherResult2<(Int, T?), (Int, T?)>, n: SignalNext<(Int, T?)>) in
				switch r {
				case .result1(.success(let v)): n.send(value: v)
				case .result1(.failure): break
				case .result2(.success(let v)): n.send(value: v)
				case .result2(.failure(let e)): n.send(error: e)
				}
			}

			_ = try? mergeSet.add(prefixedInnerSignal)
			state.index += 1
		}
	}
}

/// A `SignalMergeSet` exposes the ability to close the output signal and disconnect on deactivation. For public interfaces, neither of these is really appropriate to expose. A `SignalCollector` provides a simple wrapper around `SignalMergeSet` that forces `closesOutput` and `removeOnDeactivate` to be *false* for all inputs created through this interface.
/// A `SignalCollector` also hides details about the output from the input. Forcing `removeOnDeactivate` is one part of this but the other part is that `SignalCollector` does not `throw` from its `add` or `Signal.join` functions.
/// NOTE: it is possible to create the underlying `SignalMergeSet` and privately add inputs with other properties, if you wish.
public final class SignalCollector<T> {
	private let mergeSet: SignalMergeSet<T>
	public init(mergeSet: SignalMergeSet<T>) {
		self.mergeSet = mergeSet
	}
	
	/// Calls `add` on the underlying mergeSet with default parameters (closePropagation: SignalClosePropagation = .none, removeOnDeactivate: Bool = false)
	///
	/// NOTE: any possible error thrown by the underlying `SignalMergeSet.add` will be consumed and hidden (it's not `SignalCollector`s responsibility to communicate information about the output).
	///
	/// - Parameter source: added to the underlying merge set
	public func add(_ source: Signal<T>) {
		_ = try? mergeSet.add(source)
	}
	
	/// Calls `remove` on the underlying mergeSet
	///
	/// - Parameter source: removed from the underlying merge set
	public func remove(_ source: Signal<T>) {
		mergeSet.remove(source)
	}

	/// Creates a new `SignalInput`/`Signal` pair, immediately adds the `Signal` to this `SignalMergeSet` and returns the `SignalInput`.
	/// Equivalent to `input()` on `SignalMergeSet` with default parameters
	///
	/// - Returns: a new `SignalInput` that feeds into the collector
	public func input() -> SignalInput<T> {
		return Signal<T>.create { s -> () in self.add(s) }.input
	}
}

extension Signal {
	/// Joins this `Signal` to a destination `SignalMergeSet`
	///
	/// - Parameters:
	///   - to: the destination
	///   - closesOutput: whether errors from this `Signal` should be passed through to the `SignalMergeSet` output.
	///   - removeOnDeactivate: whether deactivate should disconnect this `Signal` from the `SignalMergeSet`.
	/// - Throws: a `SignalJoinError` if the connection is not made (see that type for details)
	public final func join(to: SignalMergeSet<T>, closePropagation: SignalClosePropagation = .none, removeOnDeactivate: Bool = false) throws {
		try to.add(self, closePropagation: closePropagation, removeOnDeactivate: removeOnDeactivate)
	}
	
	/// Joins this `Signal` to a destination `SignalMergeSet` and returns a `Cancellable` that, when cancelled, will remove the `Signal` from the `SignalMergeSet` again.
	///
	/// - Parameters:
	///   - to: target `SignalMergeSet` to which this signal will be added
	///   - closePropagation: used as a parameter to `SignalMergeSet.add`
	///   - removeOnDeactivate: used as a parameter to `SignalMergeSet.add`
	/// - Returns: a `Cancellable` that will undo the join if cancelled or released
	/// - Throws: may throw any `SignalJoinError` from `SignalMergeSet.add` (see that type for possible cases)
	public final func cancellableJoin(to: SignalMergeSet<T>, closePropagation: SignalClosePropagation = .none, removeOnDeactivate: Bool = false) throws -> Cancellable {
		try to.add(self, closePropagation: closePropagation, removeOnDeactivate: removeOnDeactivate)
		return OnDelete { [weak to, weak self] in
			guard let t = to, let s = self else { return }
			t.remove(s)
		}
	}

	/// Joins this `Signal` to a destination `SignalCollector`
	///
	/// - Parameters:
	///   - to: target `SignalCollector` to which this signal will be added
	public final func join(to: SignalCollector<T>) {
		to.add(self)
	}
	
	/// Joins this `Signal` to a destination `SignalCollector` and returns a `Cancellable` that, when cancelled, will remove the `Signal` from the `SignalCollector` again.
	///
	/// - Parameters:
	///   - to: target `SignalCollector` to which this signal will be added
	/// - Returns: a `Cancellable` that will undo the join if cancelled or released
	public final func cancellableJoin(to: SignalCollector<T>) -> Cancellable {
		to.add(self)
		return OnDelete { [weak to, weak self] in
			guard let t = to, let s = self else { return }
			t.remove(s)
		}
	}
	
	/// Create a manual input/output pair where values sent to the `input` are passed through the `signal` output.
	///
	/// - returns: the `SignalInput` and `Signal` pair
	public static func createCollector() -> (collector: SignalCollector<T>, signal: Signal<T>) {
		let (ms, s) = Signal<T>.createMergeSet()
		return (SignalCollector(mergeSet: ms), s)
	}
	
	/// Create a manual input/output pair where values sent to the `input` are passed through the `signal` output.
	///
	/// - returns: the `SignalInput` and `Signal` pair
	public static func createCollector<U>(compose: (Signal<T>) throws -> U) rethrows -> (collector: SignalCollector<T>, composed: U) {
		let (a, b) = try Signal<T>.createMergeSet(compose: compose)
		return (SignalCollector(mergeSet: a), b)
	}
}

/// This wrapper around `SignalEndpoint` exposes the last received value in a stream so that it can be 'polled' (read synchronously from an arbitrary execution context).
///
/// **WARNING**: this class should be avoided where possible since it removes the "reactive" part of reactive programming (changes in the polled value must be detected through other means, usually another subscriber to the underlying `Signal`).
///
/// The typical use-case for this type of class is in the implementation of delegate methods and similar callback functions that must synchronously return a value. Since you cannot simply `Signal.combine` the delegate method with another `Signal`, you must use polling to generate a calculation involving values from another `Signal`.
public final class SignalPollingEndpoint<T> {
	var endpoint: SignalEndpoint<T>? = nil
	var latest: Result<T>? = nil
	let queueContext = DispatchQueueContext()
	
	public init(signal: Signal<T>) {
		endpoint = signal.subscribe(context: .custom(queueContext)) { [weak self] r in
			self?.latest = r
		}
	}
	
	public var latestResult: Result<T>? {
		return queueContext.queue.sync { latest }
	}
	
	public var latestValue: T? {
		return queueContext.queue.sync { latest?.value }
	}
}

extension Signal {
	/// Appends a `SignalPollingEndpoint` listener to the value emitted from this `Signal`. The endpoint will "activate" this `Signal` and all direct antecedents in the graph (which may start lazy operations deferred until activation).
	public func pollingEndpoint() -> SignalPollingEndpoint<T> {
		return SignalPollingEndpoint(signal: self)
	}
	
	/// Internally creates a polling endpoint which is polled once for the latest Result<T> and then discarded.
	public var poll: Result<T>? {
		return SignalPollingEndpoint(signal: self).latestResult
	}
}

extension SignalInput {
	/// Create a `SignalInput`-`Signal` pair, returning the `SignalInput` and handling the `Signal` internally using the `compose` closure. This is a syntactic convenience for functions that require a `SignalInput` parameter.
	///
	/// - Parameter compose: a function that works with the `Signal` half of the newly created pair
	/// - Returns: the `SignalInput` half of the newly created pair
	/// - Throws: rethrows any error raised in the `compose` function
	public static func into(_ compose: (Signal<T>) throws -> Void) rethrows -> SignalInput<T> {
		return try Signal<T>.create { s in try compose(s) }.input
	}
	
	/// Creates a new `SignalInput`-`Signal` pair, appends a `map` transform to the `Signal` and then the transformed `Signal` is `join(to:)` self. The `SignalInput` from the pair is returned.
	///
	/// - Parameter map: a function used to map the pair's type onto the `ValueType` of `self`
	/// - Returns: the `SignalInput` half of the newly created pair
	/// - Throws: rethrows any error raised in the `compose` function
	public func viaMap<U>(_ map: @escaping (U) -> T) throws -> SignalInput<U> {
		return try .into { s in try s.map(map).join(to: self) }
	}
	
	/// Creates a new `SignalInput`-`Signal` pair, composes an arbitrary transform to the `Signal` and then the transformed `Signal` is `join(to:)` self. The `SignalInput` from the pair is returned.
	///
	/// - Parameter compose: a function that works with the `Signal` half of the newly created pair and transforms it into the desired signal to `join` to `self`
	/// - Returns: the `SignalInput` half of the newly created pair
	/// - Throws: rethrows any error raised in the `compose` function
	public func via<U>(_ compose: (Signal<U>) -> Signal<T>) throws -> SignalInput<U> {
		return try .into { s in try compose(s).join(to: self) }
	}
}

extension SignalCollector {
	/// Creates a new `SignalInput`-`Signal` pair, appends a `map` transform to the `Signal` and then the transformed `Signal` is `join(to:)` self. The `SignalInput` from the pair is returned.
	///
	/// - Parameter map: a function used to map the pair's type onto the `ValueType` of `self`
	/// - Returns: the `SignalInput` half of the newly created pair
	public func viaMap<U>(_ map: @escaping (U) -> T) -> SignalInput<U> {
		return .into { s in s.map(map).join(to: self) }
	}
	
	/// Creates a new `SignalInput`-`Signal` pair, appends a `map` transform to the `Signal` and then the transformed `Signal` is `join(to:)` self. The `SignalInput` from the pair is returned.
	///
	/// - Parameter compose: a function that works with the `Signal` half of the newly created pair and transforms it into the desired signal to `join` to `self`
	/// - Returns: the `SignalInput` half of the newly created pair
	public func via<U>(_ compose: (Signal<U>) -> Signal<T>) -> SignalInput<U> {
		return .into { s in compose(s).join(to: self) }
	}
}

extension SignalCapture {
	/// A convenience version of `subscribe` that only invokes the `processor` on `Result.success`
	///
	/// - Parameters:
	///   - resend: if true, captured values are sent to the new output as the first values in the stream, otherwise, captured values are not sent (default is false)
	///   - context: the execution context where the `processor` will be invoked
	///   - processor: will be invoked with each value received
	/// - Returns: the `SignalEndpoint` created by this function
	public func subscribeValues(resend: Bool = false, context: Exec = .direct, handler: @escaping (T) -> Void) -> SignalEndpoint<T> {
		let (input, output) = Signal<T>.create()
		try! join(to: input, resend: resend)
		return output.subscribeValues(context: context, handler: handler)
	}
	
	/// A convenience version of `subscribe` that only invokes the `processor` on `Result.success`
	///
	/// - Parameters:
	///   - resend: if true, captured values are sent to the new output as the first values in the stream, otherwise, captured values are not sent (default is false)
	///   - onError: if nil, errors from self will be passed through to `toInput`'s `Signal` normally. If non-nil, errors will not be sent, instead, the `Signal` will be disconnected and the `onError` function will be invoked with the disconnected `SignalCapture` and the input created by calling `disconnect` on it.
	///   - context: the execution context where the `processor` will be invoked
	///   - processor: will be invoked with each value received
	/// - Returns: the `SignalEndpoint` created by this function
	public func subscribeValues(resend: Bool = false, onError: @escaping (SignalCapture<T>, Error, SignalInput<T>) -> (), context: Exec = .direct, handler: @escaping (T) -> Void) -> SignalEndpoint<T> {
		let (input, output) = Signal<T>.create()
		try! join(to: input, resend: resend, onError: onError)
		return output.subscribeValues(context: context, handler: handler)
	}
}

extension Result {
	/// A convenience extension on `Result` to test if it wraps a `SignalError.closed`
	public var isSignalClosed: Bool {
		return error as? SignalError == .closed
	}
}
//
//  CwlSignalReactive.swift
//  CwlSignal
//
//  Created by Matt Gallagher on 2016/09/08.
//  Copyright © 2016 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

#if swift(>=4)
#else
	public typealias Numeric = IntegerArithmetic & ExpressibleByIntegerLiteral
	public typealias BinaryInteger = IntegerArithmetic & ExpressibleByIntegerLiteral
#endif

extension Signal {
	/// - Note: the [Reactive X operator "Create"](http://reactivex.io/documentation/operators/create.html) is considered unnecessary, given the `CwlSignal.Signal.generate` and `CwlSignal.Signal.create` methods.
	
	/// - Note: the [Reactive X operator "Defer"](http://reactivex.io/documentation/operators/defer.html) is considered not applicable, given the different semantics of "activation" with `CwlSignal.Signal`. If `Defer`-like behavior is desired, either a method that constructs and returns a new `Signal` graph should be used (if a truly distinct graph is desired) or `CwlSignal.Signal.generate` should be used (if wait-until-activated behavior is desired).
	
	/// - Note: the Reactive X operator [Reactive X operator "Empty"](http://reactivex.io/documentation/operators/empty-never-throw.html) is redundant with the default invocation of `CwlSignal.Signal.preclosed`
}

extension Signal {
	/// Implementation of [Reactive X operator "Never"](http://reactivex.io/documentation/operators/empty-never-throw.html)
	///
	/// - returns: a non-sending, non-closing signal of the desired type
	public static func never() -> Signal<T> {
		return .from(values: [], error: nil)
	}
	
	/// Implementation of [Reactive X operator "From"](http://reactivex.io/documentation/operators/from.html) in the context of the Swift `Sequence`
	///
	/// NOTE: it is possible to specify a `nil` error to have the signal remain open at the end of the sequence.
	///
	/// - parameter values: A Swift `Sequence` that generates the signal values.
	/// - parameter error: The error with which to close the sequence. Can be `nil` to leave the sequence open (default: `SignalError.closed`)
	/// - parameter context: the `Exec` where the `SequenceType` will be enumerated (default: .direct).
	/// - returns: a signal that emits `values` and then closes
	public static func from<S: Sequence>(values: S, error: Error? = SignalError.closed, context: Exec = .direct) -> Signal<T> where S.Iterator.Element == T {
		if let e = error {
			return generate(context: context) { input in
				guard let i = input else { return }
				for v in values {
					if let _ = i.send(value: v) {
						break
					}
				}
				i.send(error: e)
			}
		} else {
			return retainedGenerate(context: context) { input in
				guard let i = input else { return }
				for v in values {
					if let _ = i.send(value: v) {
						break
					}
				}
			}
		}
	}
	
	/// Implementation of [Reactive X operator "To"](http://reactivex.io/documentation/operators/to.html) in the context of the Swift `Sequence`
	///
	/// WARNING: Because it blocks the receiving thread, and because it undermines the principle of *reactive* programming, this function should only be used in specific circumstances.
	///
	/// `SignalSequence` subscribes to `self` and blocks. This means that if any earlier signals in the graph force processing on the same context where `SignalSequence` is iterated, a deadlock may occur between the iteration and the signal processing.
	/// This function is safe only when you can guarantee all parts of the signal graph are independent of the blocking context.
	public func toSequence() -> SignalSequence<T> {
		return SignalSequence<T>(self)
	}
}

/// Represents a Signal<T> converted to a synchronously iterated sequence. Values can be obtained using typical SequenceType actions. The error that ends the sequence is available through the `error` property.
public class SignalSequence<T>: Sequence, IteratorProtocol {
	typealias GeneratorType = SignalSequence<T>
	typealias ElementType = T
	
	let semaphore = DispatchSemaphore(value: 0)
	let context = Exec.syncQueue()
	var endpoint: SignalEndpoint<T>? = nil
	
	var queued: Array<T> = []
	
	/// Error type property is `nil` before the end of the signal is reached and contains the error used to close the signal in other cases
	public var error: Error?
	
	// Only intended to be constructed by `Signal.toSequence`
	//
	// - Parameter signal: the signal whose values will be iterated by this sequence
	init(_ signal: Signal<T>) {
		endpoint = signal.subscribe(context: context) { [weak self] (r: Result<T>) in
			guard let s = self else { return }
			switch r {
			case .success(let v):
				s.queued.append(v)
				s.semaphore.signal()
			case .failure(let e):
				s.error = e
				s.semaphore.signal()
			}
		}
	}
	
	/// Stops listening to the signal and set the error value to SignalError.Cancelled
	public func cancel() {
		context.invokeAndWait {
			self.error = SignalError.cancelled
			self.endpoint?.cancel()
			self.semaphore.signal()
		}
	}
	
	/// Implementation of GeneratorType method.
	public func next() -> T? {
		_ = semaphore.wait(timeout: DispatchTime.distantFuture)
		var result: T? = nil
		context.invokeAndWait { [weak self] in
			guard let s = self else { return }
			if !s.queued.isEmpty {
				result = s.queued.removeFirst()
			} else {
				// Signal the sempahore so that `nil` can be fetched again.
				s.semaphore.signal()
			}
		}
		return result
	}
	
	deinit {
		if error == nil {
			semaphore.signal()
		}
	}
}

/// Implementation of [Reactive X operator "Interval"](http://reactivex.io/documentation/operators/interval.html)
///
/// - Parameters:
///   - interval: duration between values
///   - initialInterval: duration until first value
///   - context: execution context where the timer will run
/// - Returns: the interval signal
public func intervalSignal(_ interval: DispatchTimeInterval, initial initialInterval: DispatchTimeInterval? = nil, context: Exec = .default) -> Signal<Int> {
	// We need to protect the `count` variable and make sure that out-of-date timers don't update it so we use a `serialized` context for the `generate` and the timers, since the combination of the two will ensure that these requirements are met.
	let serialContext = context.serialized()
	var timer: Cancellable? = nil
	var count = 0
	
	return Signal<Int>.generate(context: serialContext) { input in
		guard let i = input else {
			timer?.cancel()
			count = 0
			return
		}
		
		let repeater = {
			timer = serialContext.periodicTimer(interval: interval) {
				i.send(value: count)
				count += 1
			}
		}
		
		if let initial = initialInterval {
			timer = serialContext.singleTimer(interval: initial) {
				i.send(value: count)
				count += 1
				repeater()
			}
		} else {
			repeater()
		}
	}
}

extension Signal {
	/// - Note: the [Reactive X operator "Just"](http://reactivex.io/documentation/operators/just.html) is redundant with the default invocation of `CwlSignal.Signal.preclosed`
	
	/// - Note: the [Reactive X operator `Range`](http://reactivex.io/documentation/operators/range.html) is considered unnecessary, given the `CwlSignal.Signal.fromSequence`. Further, since Swift uses multiple different *kinds* of range, multiple implementations would be required. Doesn't seem worth the effort.
}

extension Signal {
	/// Implementation of [Reactive X operator "Repeat"](http://reactivex.io/documentation/operators/repeat.html) for a Swift `CollectionType`
	///
	/// - Parameters:
	///   - values: A Swift `CollectionType` that generates the signal values.
	///   - count: the number of times that `values` will be repeated.
	///   - context: the `Exec` where the `SequenceType` will be enumerated.
	/// - Returns: a signal that emits `values` a `count` number of times and then closes
	public static func repeatCollection<C: Collection>(_ values: C, count: Int, context: Exec = .direct) -> Signal<T> where C.Iterator.Element == T {
		return generate(context: context) { input in
			guard let i = input else { return }
			for _ in 0..<count {
				for v in values {
					if i.send(value: v) != nil {
						break
					}
				}
			}
			i.close()
		}
	}
	
	/// Implementation of [Reactive X operator "Start"](http://reactivex.io/documentation/operators/start.html)
	///
	/// - Parameters:
	///   - context: the `Exec` where `f` will be evaluated (default: .direct).
	///   - f: a function that is run to generate the value.
	/// - Returns: a signal that emits a single value emitted from a function
	public static func start(context: Exec = .direct, f: @escaping () -> T) -> Signal<T> {
		return Signal.generate(context: context) { input in
			guard let i = input else { return }
			i.send(value: f())
			i.close()
		}
	}
	
	/// Implementation of [Reactive X operator "Timer"](http://reactivex.io/documentation/operators/timer.html)
	///
	/// - Parameters:
	///   - interval: the time until the value is sent.
	///   - value: the value that will be sent before closing the signal (if `nil` then the signal will simply be closed at the end of the timer)
	///   - context: execution context where the timer will be run
	/// - Returns: the timer signal
	public static func timer(interval: DispatchTimeInterval, value: T? = nil, context: Exec = .default) -> Signal<T> {
		var timer: Cancellable? = nil
		return Signal<T>.generate(context: context) { input in
			if let i = input {
				timer = context.singleTimer(interval: interval) {
					if let v = value {
						i.send(value: v)
					}
					i.close()
				}
			} else {
				timer?.cancel()
			}
		}
	}
	
	/// A shared function for emitting a boundary signal usable by the timed, non-overlapping buffer/window functions buffer(timeshift:count:continuous:behavior:) or window(timeshift:count:continuous:behavior:)
	///
	/// - Parameters:
	///   - interval: maximum duration between boundaries
	///   - count: maximum number of signal values between boundaries
	///   - continuous: timer is paused immediately after a boundary until the next value is received
	///   - context: execution context where the timer will be run
	/// - Returns: the boundary signal
	private func timedCountedBoundary(interval: DispatchTimeInterval, count: Int, continuous: Bool, context: Exec) -> Signal<()> {
		// An interval signal
		let intSig = intervalSignal(interval, context: context)
		
		if count == Int.max {
			// If number of values per boundary is infinite, then all we need is the timer signal
			return intSig.map { v in () }
		}
		
		// The interval signal may need to be disconnectable so create a junction
		let intervalJunction = intSig.junction()
		let (initialInput, signal) = Signal<Int>.create()
		
		// Continuous signals don't really need the junction. Just connect it immediately and ignore it.
		if continuous {
			do {
				try intervalJunction.join(to: initialInput)
			} catch {
				assertionFailure()
				return Signal<()>.preclosed()
			}
		}
		
		return combine(initialState: (0, nil), second: signal) { (state: inout (count: Int, timerInput: SignalInput<Int>?), cr: EitherResult2<T, Int>, n: SignalNext<()>) in
			var send = false
			switch cr {
			case .result1(.success):
				// Count the values received per window
				state.count += 1
				
				// If we hit `count` values, trigger the boundary signal
				if state.count == count {
					send = true
				} else if !continuous, let i = state.timerInput {
					// If we're not continuous, make sure the timer is connected
					do {
						try intervalJunction.join(to: i)
					} catch {
						n.send(error: error)
					}
				}
			case .result1(.failure(let e)):
				// If there's an error on the `self` signal, forward it on.
				n.send(error: e)
			case .result2(.success):
				// When the timer fires, trigger the boundary signal
				send = true
			case .result2(.failure(let e)):
				// If there's a timer error, close
				n.send(error: e)
			}
			
			if send {
				// Send the boundary signal
				n.send(value: ())
				
				// Reset the count and – if not continuous – disconnect the timer until we receive a signal from `self`
				state.count = 0
				if !continuous {
					state.timerInput = intervalJunction.disconnect()
				}
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Buffer"](http://reactivex.io/documentation/operators/buffer.html) for non-overlapping/no-gap buffers.
	///
	/// - Parameter boundaries: when this `Signal` sends a value, the buffer is emitted and cleared
	/// - Returns: a signal where the values are arrays of values from `self`, accumulated according to `boundaries`
	public func buffer<U>(boundaries: Signal<U>) -> Signal<[T]> {
		return combine(initialState: [T](), second: boundaries) { (buffer: inout [T], cr: EitherResult2<T, U>, next: SignalNext<[T]>) in
			switch cr {
			case .result1(.success(let v)):
				buffer.append(v)
			case .result1(.failure(let e)):
				next.send(value: buffer)
				buffer.removeAll()
				next.send(error: e)
			case .result2(.success):
				next.send(value: buffer)
				buffer.removeAll()
			case .result2(.failure(let e)):
				next.send(value: buffer)
				buffer.removeAll()
				next.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Buffer"](http://reactivex.io/documentation/operators/buffer.html) for buffers with overlap or gaps between.
	///
	/// - Parameter windows: a "windows" signal (one that describes a series of times and durations). Each value `Signal` in the stream starts a new buffer and when the value `Signal` closes, the buffer is emitted.
	/// - Returns: a signal where the values are arrays of values from `self`, accumulated according to `windows`
	public func buffer<U>(windows: Signal<Signal<U>>) -> Signal<[T]> {
		return combine(initialState: [Int: [T]](), second: windows.valueDurations { s in s }) { (buffers: inout [Int: [T]], cr: EitherResult2<T, (Int, Signal<U>?)>, next: SignalNext<[T]>) in
			switch cr {
			case .result1(.success(let v)):
				for index in buffers.keys {
					buffers[index]?.append(v)
				}
			case .result1(.failure(let e)):
				for (_, b) in buffers {
					next.send(value: b)
				}
				buffers.removeAll()
				next.send(error: e)
			case .result2(.success(let index, .some)):
				buffers[index] = []
			case .result2(.success(let index, .none)):
				if let b = buffers[index] {
					next.send(value: b)
					buffers.removeValue(forKey: index)
				}
			case .result2(.failure(let e)):
				for (_, b) in buffers {
					next.send(value: b)
				}
				buffers.removeAll()
				next.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Buffer"](http://reactivex.io/documentation/operators/buffer.html) for buffers of fixed length and a fixed number of values separating starts.
	///
	/// - Parameters:
	///   - count: the number of separate values to accumulate before emitting an array of values
	///   - skip: the stride between the start of each new buffer (can be smaller than `count`, resulting in overlapping buffers)
	/// - Returns: a signal where the values are arrays of length `count` of values from `self`, with start values separated by `skip`
	public func buffer(count: UInt, skip: UInt) -> Signal<[T]> {
		if count == 0 {
			return Signal<[T]>.preclosed()
		}
		
		let multi = multicast()
		
		// Create the two listeners to the "multi" signal carefully so that the window signal is *first* (so it reaches the buffer before the value signal)
		let windowSignal = multi.stride(count: Int(skip)).map { _ in
			// `count - 1` is the index of the count-th element but since `valuesSignal` will resolve before this, we need to fire 1 element sooner, hence `count - 2`
			multi.elementAt(count - 2).ignoreElements()
		}
		
		return multi.buffer(windows: windowSignal)
	}
	
	/// Implementation of [Reactive X operator "Buffer"](http://reactivex.io/documentation/operators/buffer.html) for non-overlapping, periodic buffer start times and possibly limited buffer sizes.
	///
	/// - Parameters:
	///   - interval: number of seconds between the start of each buffer
	///   - count: the number of separate values to accumulate before emitting an array of values
	///   - continuous: if `true` (default), the `timeshift` periodic timer runs continuously (empty buffers may be emitted if a timeshift elapses without any source signals). If `false`, the periodic timer does start until the first value is received from the source and the periodic timer is paused when a buffer is emitted.
	///   - context: context where the timer will be run
	/// - Returns: a signal where the values are arrays of values from `self`, accumulated according to `windows
	public func buffer(interval: DispatchTimeInterval, count: Int = Int.max, continuous: Bool = true, context: Exec = .direct) -> Signal<[T]> {
		let multi = multicast()
		
		// Create the two listeners to the "multi" signal carefully so that the raw signal is *first* (so it reaches the buffer before the boundary signal)
		let valuesSignal = multi.map { v in v }
		let boundarySignal = multi.timedCountedBoundary(interval: interval, count: count, continuous: continuous, context: context)
		
		return valuesSignal.buffer(boundaries: boundarySignal)
	}
	
	/// Implementation of [Reactive X operator "Buffer"](http://reactivex.io/documentation/operators/buffer.html) for non-overlapping buffers of fixed length.
	///
	/// - Note: this is just a convenience wrapper around `buffer(count:skip:behavior)` where `skip` equals `count`.
	///
	/// - Parameter count: the number of separate values to accumulate before emitting an array of values
	/// - Returns: a signal where the values are arrays of values from `self`, accumulated according to `count`
	public func buffer(count: UInt) -> Signal<[T]> {
		return buffer(count: count, skip: count)
	}
	
	/// Implementation of [Reactive X operator "Buffer"](http://reactivex.io/documentation/operators/buffer.html) for periodic buffer start times and fixed duration buffers.
	///
	/// - Note: this is just a convenience wrapper around `buffer(windows:behaviors)` where the `windows` signal contains `timerSignal` signals contained in a `intervalSignal` signal.
	///
	/// - Parameters:
	///   - interval: the duration of each buffer, in seconds.
	///   - timeshift: the number of seconds between the start of each buffer (if smaller than `interval`, buffers will overlap).
	///   - context: context where the timer will be run
	/// - Returns: a signal where the values are arrays of values from `self`, accumulated according to `windows`
	public func buffer(interval: DispatchTimeInterval, timeshift: DispatchTimeInterval, context: Exec = .direct) -> Signal<[T]> {
		return buffer(windows: intervalSignal(timeshift, initial: .seconds(0), context: context).map { v in Signal<()>.timer(interval: interval, context: context) })
	}
	
	/// Implementation of map and filter. Essentially a flatMap but instead of flattening over child `Signal`s like the standard Reactive implementation, this flattens over child `Optional`s.
	///
	/// - Parameters:
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a new `Signal`
	/// - Returns: a signal where every value from every `Signal` output by `processor` is merged into a single stream
	public func filterMap<U>(context: Exec = .direct, _ processor: @escaping (T) -> U?) -> Signal<U> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<U>) in
			switch r {
			case .success(let v):
				if let u = processor(v) {
					n.send(value: u)
				}
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// Implementation of map and filter. Essentially a flatMap but instead of flattening over child `Signal`s like the standard Reactive implementation, this flattens over child `Optional`s.
	///
	/// - Parameters:
	///   - initialState: an initial value for a state parameter that will be passed to the processor on each iteration.
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a new `Signal`
	/// - Returns: a signal where every value from every `Signal` output by `processor` is merged into a single stream
	public func filterMap<S, U>(initialState: S, context: Exec = .direct, _ processor: @escaping (inout S, T) -> U?) -> Signal<U> {
		return transform(initialState: initialState, context: context) { (s: inout S, r: Result<T>, n: SignalNext<U>) in
			switch r {
			case .success(let v):
				if let u = processor(&s, v) {
					n.send(value: u)
				}
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// Implementation of map where the closure can throw. Essentially a flatMap but instead of flattening over child `Signal`s like the standard Reactive implementation, this flattens over values or thrown errors.
	///
	/// - Parameters:
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a new `Signal`
	/// - Returns: a signal where every value from every `Signal` output by `processor` is merged into a single stream
	public func failableMap<U>(context: Exec = .direct, _ processor: @escaping (T) throws -> U) -> Signal<U> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<U>) in
			switch r {
			case .success(let v):
				do {
					let u = try processor(v)
					n.send(value: u)
				} catch {
					n.send(error: error)
				}
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// Implementation of map where the closure can throw. Essentially a flatMap but instead of flattening over child `Signal`s like the standard Reactive implementation, this flattens over values or thrown errors.
	///
	/// - Parameters:
	///   - initialState: an initial value for a state parameter that will be passed to the processor on each iteration.
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a new `Signal`
	/// - Returns: a signal where every value from every `Signal` output by `processor` is merged into a single stream
	public func failableMap<S, U>(initialState: S, context: Exec = .direct, _ processor: @escaping (inout S, T) throws -> U) -> Signal<U> {
		return transform(initialState: initialState, context: context) { (s: inout S, r: Result<T>, n: SignalNext<U>) in
			switch r {
			case .success(let v):
				do {
					let u = try processor(&s, v)
					n.send(value: u)
				} catch {
					n.send(error: error)
				}
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// Implementation of map where the closure can throw. Essentially a flatMap but instead of flattening over child `Signal`s like the standard Reactive implementation, this flattens over values or thrown errors.
	///
	/// - Parameters:
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a new `Signal`
	/// - Returns: a signal where every value from every `Signal` output by `processor` is merged into a single stream
	public func failableFilterMap<U>(context: Exec = .direct, _ processor: @escaping (T) throws -> U?) -> Signal<U> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<U>) in
			switch r {
			case .success(let v):
				do {
					if let u = try processor(v) {
						n.send(value: u)
					}
				} catch {
					n.send(error: error)
				}
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// Implementation of map where the closure can throw. Essentially a flatMap but instead of flattening over child `Signal`s like the standard Reactive implementation, this flattens over values or thrown errors.
	///
	/// - Parameters:
	///   - initialState: an initial value for a state parameter that will be passed to the processor on each iteration.
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a new `Signal`
	/// - Returns: a signal where every value from every `Signal` output by `processor` is merged into a single stream
	public func failableFilterMap<S, U>(initialState: S, context: Exec = .direct, _ processor: @escaping (inout S, T) throws -> U?) -> Signal<U> {
		return transform(initialState: initialState, context: context) { (s: inout S, r: Result<T>, n: SignalNext<U>) in
			switch r {
			case .success(let v):
				do {
					if let u = try processor(&s, v) {
						n.send(value: u)
					}
				} catch {
					n.send(error: error)
				}
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "FlatMap"](http://reactivex.io/documentation/operators/flatmap.html)
	///
	/// - Parameters:
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a new `Signal`
	/// - Returns: a signal where every value from every `Signal` output by `processor` is merged into a single stream
	public func flatMap<U>(context: Exec = .direct, _ processor: @escaping (T) -> Signal<U>) -> Signal<U> {
		return transformFlatten(closePropagation: .errors, context: context) { (v: T, mergeSet: SignalMergeSet<U>) in
			_ = try? mergeSet.add(processor(v), closePropagation: .errors, removeOnDeactivate: true)
		}
	}
	
	/// Implementation of [Reactive X operator "FlatMapFirst"](http://reactivex.io/documentation/operators/flatmap.html)
	///
	/// - Parameters:
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a new `Signal`
	/// - Returns: a signal where every value from every `Signal` output by `processor` is merged into a single stream
	public func flatMapFirst<U>(context: Exec = .direct, _ processor: @escaping (T) -> Signal<U>) -> Signal<U> {
		return transformFlatten(initialState: false, closePropagation: .errors, context: context) { (s: inout Bool, v: T, mergeSet: SignalMergeSet<U>) in
			if !s {
				_ = try? mergeSet.add(processor(v), closePropagation: .errors, removeOnDeactivate: true)
				s = true
			}
		}
	}
	
	/// Implementation of [Reactive X operator "FlatMapLatest"](http://reactivex.io/documentation/operators/flatmap.html)
	///
	/// See also `switchLatestSignal`
	///
	/// - Parameters:
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a new `Signal`
	/// - Returns: a signal where every value from every `Signal` output by `processor` is merged into a single stream
	public func flatMapLatest<U>(context: Exec = .direct, _ processor: @escaping (T) -> Signal<U>) -> Signal<U> {
		return transformFlatten(initialState: nil, closePropagation: .errors, context: context) { (s: inout Signal<U>?, v: T, mergeSet: SignalMergeSet<U>) in
			if let existing = s {
				mergeSet.remove(existing)
			}
			let next = processor(v)
			_ = try? mergeSet.add(next, closePropagation: .errors, removeOnDeactivate: true)
			s = next
		}
	}
	
	/// Implementation of [Reactive X operator "FlatMap"](http://reactivex.io/documentation/operators/flatmap.html)
	///
	/// - Parameters:
	///   - initialState: an initial value for a state parameter that will be passed to the processor on each iteration.
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a new `Signal`
	/// - Returns: a signal where every value from every `Signal` output by `processor` is merged into a single stream
	public func flatMap<U, V>(initialState: V, context: Exec = .direct, _ processor: @escaping (inout V, T) -> Signal<U>) -> Signal<U> {
		return transformFlatten(initialState: initialState, closePropagation: .errors, context: context) { (s: inout V, v: T, mergeSet: SignalMergeSet<U>) in
			_ = try? mergeSet.add(processor(&s, v), closePropagation: .errors, removeOnDeactivate: true)
		}
	}
	
	/// Implementation of [Reactive X operator "ConcatMap"](http://reactivex.io/documentation/operators/flatmap.html)
	///
	/// - Parameters:
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a new `Signal`
	/// - Returns: a signal where every value from every `Signal` output by `processor` is serially concatenated into a single stream
	public func concatMap<U>(context: Exec = .direct, _ processor: @escaping (T) -> Signal<U>) -> Signal<U> {
		return transformFlatten(initialState: 0, closePropagation: .errors, context: context) { (index: inout Int, v: T, mergeSet: SignalMergeSet<(Int, Result<U>)>) in
			_ = try? mergeSet.add(processor(v).transform { (r: Result<U>, n: SignalNext<Result<U>>) in
				switch r {
				case .success:
					n.send(value: r)
				case .failure(let e):
					n.send(value: r)
					n.send(error: e)
				}
			}.map { [index] (r: Result<U>) -> (Int, Result<U>) in (index, r) }, closePropagation: .errors, removeOnDeactivate: true)
			index += 1
		}.transform(initialState: (0, Array<Array<Result<U>>>())) { (state: inout (completed: Int, buffers: Array<Array<Result<U>>>), result: Result<(Int, Result<U>)>, next: SignalNext<U>) in
			switch result {
			case .success(let index, .success(let v)):
				// We can send results for the first incomplete signal without buffering
				if index == state.completed {
					next.send(value: v)
				} else {
					// Make sure we have enough buffers
					while index >= state.buffers.count {
						state.buffers.append([])
					}
					
					// Buffer the result
					state.buffers[index].append(Result<U>.success(v))
				}
			case .success(let index, .failure(let e)):
				// If its an error, try to send some more buffers
				if index == state.completed {
					state.completed += 1
					for i in state.completed..<state.buffers.count {
						for j in state.buffers[i] where !j.isError {
							next.send(result: j)
						}
						
						let incomplete = state.buffers[i].last?.isError != true
						state.buffers[i].removeAll()
						if incomplete {
							break
						}
						state.completed += 1
					}
				} else {
					// If we're not up to that buffer, just record the error
					state.buffers[index].append(Result<U>.failure(e))
				}
			case .failure(let error): next.send(error: error)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "GroupBy"](http://reactivex.io/documentation/operators/groupby.html)
	///
	/// - Parameters:
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs the "key" for the output `Signal`
	/// - Returns: a parent `Signal` where values are tuples of a "key" and a child `Signal` that will contain all values from `self` associated with that "key".
	public func groupBy<U: Hashable>(context: Exec = .direct, _ processor: @escaping (T) -> U) -> Signal<(U, Signal<T>)> {
		return self.transform(initialState: Dictionary<U, SignalInput<T>>(), context: context) { (outputs: inout Dictionary<U, SignalInput<T>>, r: Result<T>, n: SignalNext<(U, Signal<T>)>) in
			switch r {
			case .success(let v):
				let u = processor(v)
				if let o = outputs[u] {
					o.send(value: v)
				} else {
					let (input, signal) = Signal<T>.create { s in s.cacheUntilActive() }
					input.send(value: v)
					n.send(value: (u, signal))
					outputs[u] = input
				}
			case .failure(let e):
				n.send(error: e)
				outputs.forEach { tuple in tuple.value.send(error: e) }
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Map"](http://reactivex.io/documentation/operators/map.html)
	///
	/// - Parameters:
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a value for the output `Signal`
	/// - Returns: a `Signal` where all the values have been transformed by the `processor`. Any error is emitted in the output without change.
	public func map<U>(context: Exec = .direct, _ processor: @escaping (T) -> U) -> Signal<U> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<U>) in
			switch r {
			case .success(let v): n.send(value: processor(v))
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Map"](http://reactivex.io/documentation/operators/map.html)
	///
	/// - Parameters:
	///   - initialState: an initial value for a state parameter that will be passed to the processor on each iteration.
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: for each value emitted by `self`, outputs a value for the output `Signal`
	/// - Returns: a `Signal` where all the values have been transformed by the `processor`. Any error is emitted in the output without change.
	public func map<U, V>(initialState: V, context: Exec = .direct, _ processor: @escaping (inout V, T) -> U) -> Signal<U> {
		return transform(initialState: initialState, context: context) { (s: inout V, r: Result<T>, n: SignalNext<U>) in
			switch r {
			case .success(let v): n.send(value: processor(&s, v))
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Scan"](http://reactivex.io/documentation/operators/scan.html)
	///
	/// NOTE: this function is effectively a `reduce` that emits each progressive accumulated value
	///
	/// - Parameters:
	///   - initialState: an initial value for a state parameter that will be passed to the processor on each iteration.
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: takes the most recently emitted value and the most recent value from `self` and returns the next emitted value
	/// - Returns: a `Signal` where the result from each invocation of `processor` are emitted
	public func scan<U>(initialState: U, context: Exec = .direct, _ processor: @escaping (U, T) -> U) -> Signal<U> {
		return transform(initialState: initialState, context: context) { (accumulated: inout U, r: Result<T>, n: SignalNext<U>) in
			switch r {
			case .success(let v):
				accumulated = processor(accumulated, v)
				n.send(value: accumulated)
			case .failure(let e):
				n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Window"](http://reactivex.io/documentation/operators/window.html) for non-overlapping/no-gap buffers.
	///
	/// - Note: equivalent to "buffer" method with same parameters
	///
	/// - Parameter boundaries: when this `Signal` sends a value, the buffer is emitted and cleared
	/// - Returns: a signal where the values are arrays of values from `self`, accumulated according to `boundaries`
	public func window<U>(boundaries: Signal<U>) -> Signal<Signal<T>> {
		return combine(initialState: nil, second: boundaries) { (current: inout SignalInput<T>?, cr: EitherResult2<T, U>, next: SignalNext<Signal<T>>) in
			switch cr {
			case .result1(.success(let v)):
				if current == nil {
					let (i, s) = Signal<T>.create()
					current = i
					next.send(value: s)
				}
				if let c = current {
					c.send(value: v)
				}
			case .result1(.failure(let e)):
				next.send(error: e)
			case .result2(.success):
				_ = current?.close()
				current = nil
			case .result2(.failure(let e)):
				next.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Window"](http://reactivex.io/documentation/operators/window.html) for buffers with overlap or gaps between.
	///
	/// - Note: equivalent to "buffer" method with same parameters
	///
	/// - Parameter windows: a "windows" signal (one that describes a series of times and durations). Each value `Signal` in the stream starts a new buffer and when the value `Signal` closes, the buffer is emitted.
	/// - Returns: a signal where the values are arrays of values from `self`, accumulated according to `windows`
	public func window<U>(windows: Signal<Signal<U>>) -> Signal<Signal<T>> {
		return combine(initialState: [Int: SignalInput<T>](), second: windows.valueDurations { s in s }) { (children: inout [Int: SignalInput<T>], cr: EitherResult2<T, (Int, Signal<U>?)>, next: SignalNext<Signal<T>>) in
			switch cr {
			case .result1(.success(let v)):
				for index in children.keys {
					if let c = children[index] {
						c.send(value: v)
					}
				}
			case .result1(.failure(let e)):
				next.send(error: e)
			case .result2(.success(let index, .some)):
				let (i, s) = Signal<T>.create()
				children[index] = i
				next.send(value: s)
			case .result2(.success(let index, .none)):
				if let c = children[index] {
					c.close()
					children.removeValue(forKey: index)
				}
			case .result2(.failure(let e)):
				next.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Window"](http://reactivex.io/documentation/operators/window.html) for buffers of fixed length and a fixed number of values separating starts.
	///
	/// - Note: equivalent to "buffer" method with same parameters
	///
	/// - Parameters:
	///   - count: the number of separate values to accumulate before emitting an array of values
	///   - skip: the stride between the start of each new buffer (can be smaller than `count`, resulting in overlapping buffers)
	/// - Returns: a signal where the values are arrays of length `count` of values from `self`, with start values separated by `skip`
	public func window(count: UInt, skip: UInt) -> Signal<Signal<T>> {
		let multi = multicast()
		
		// Create the two listeners to the "multi" signal carefully so that the window signal is *first* (so it reaches the buffer before the value signal)
		let windowSignal = multi.stride(count: Int(skip)).map { v in
			// `count - 1` is the index of the count-th element but since `valuesSignal` will resolve before this, we need to fire 1 element sooner, hence `count - 2`
			multi.elementAt(count - 2).ignoreElements()
		}
		
		return multi.window(windows: windowSignal)
	}
	
	/// Implementation of [Reactive X operator "Window"](http://reactivex.io/documentation/operators/window.html) for non-overlapping, periodic buffer start times and possibly limited buffer sizes.
	///
	/// - Note: equivalent to "buffer" method with same parameters
	///
	/// - Parameters:
	///   - interval: the number of seconds between the start of each buffer
	///   - count: the number of separate values to accumulate before emitting an array of values
	///   - continuous: if `true` (default), the `timeshift` periodic timer runs continuously (empty buffers may be emitted if a timeshift elapses without any source signals). If `false`, the periodic timer does start until the first value is received from the source and the periodic timer is paused when a buffer is emitted.
	///   - context: context where the timer will run
	/// - Returns: a signal where the values are arrays of values from `self`, accumulated according to `windows`
	public func window(interval: DispatchTimeInterval, count: Int = Int.max, continuous: Bool = true, context: Exec = .direct) -> Signal<Signal<T>> {
		let multi = multicast()
		
		// Create the two listeners to the "multi" signal carefully so that the raw signal is *first* (so it reaches the buffer before the boundary signal)
		let valuesSignal = multi.map { v in v }
		let boundarySignal = multi.timedCountedBoundary(interval: interval, count: count, continuous: continuous, context: context)
		
		return valuesSignal.window(boundaries: boundarySignal)
	}
	
	/// Implementation of [Reactive X operator "Window"](http://reactivex.io/documentation/operators/window.html) for non-overlapping buffers of fixed length.
	///
	/// - Note: this is just a convenience wrapper around `buffer(count:skip:behavior)` where `skip` equals `count`.
	/// - Note: equivalent to "buffer" method with same parameters
	///
	/// - Parameter count: the number of separate values to accumulate before emitting an array of values
	/// - Returns: a signal where the values are arrays of values from `self`, accumulated according to `count`
	public func window(count: UInt) -> Signal<Signal<T>> {
		return window(count: count, skip: count)
	}
	
	/// Implementation of [Reactive X operator "Window"](http://reactivex.io/documentation/operators/window.html) for periodic buffer start times and fixed duration buffers.
	///
	/// - Note: this is just a convenience wrapper around `buffer(windows:behaviors)` where the `windows` signal contains `timerSignal` signals contained in a `intervalSignal` signal.
	/// - Note: equivalent to "buffer" method with same parameters
	///
	/// - Parameters:
	///   - interval: the duration of each buffer, in seconds
	///   - timeshift: the number of seconds between the start of each buffer (if smaller than `interval`, buffers will overlap).
	///   - context: context where the timer will run
	/// - Returns: a signal where the values are arrays of values from `self`, accumulated according to `windows`
	public func window(interval: DispatchTimeInterval, timeshift: DispatchTimeInterval, context: Exec = .direct) -> Signal<Signal<T>> {
		return window(windows: intervalSignal(timeshift, initial: .seconds(0), context: context).map { v in Signal<()>.timer(interval: interval, context: context) })
	}
	
	/// Implementation of [Reactive X operator "Debounce"](http://reactivex.io/documentation/operators/debounce.html)
	///
	/// - Parameters:
	///   - interval: the duration over which to drop values.
	///   - flushOnClose: if true, then any buffered value is sent before closing, if false then the buffered value is discarded when a close occurs
	///   - context: context where the timer will run
	/// - Returns: a signal where values are emitted after a `interval` but only if no another value occurs during that `interval`.
	public func debounce(interval: DispatchTimeInterval, flushOnClose: Bool = true, context: Exec = .direct) -> Signal<T> {
		// The topology of this construction is particularly weird.
		// Basically...
		//
		//     -> incoming signal -> combiner -> post delay emission ->
		//                           ^      \
		//                           \______/
		//               delayed values held by `singleTimer`
		//                  closure, sent to `timerInput`
		//
		// The weird structure of the loopback (using an input pulled from a `generate` function) is so that the overall function remains robust under deactivation and reactivation. The mutable `timerInput` is protected by the serialized `context`, shared between the `generate` and the `combine`.
		let serialContext = context.serialized()
		var timerInput: SignalInput<T>? = nil
		let timerSignal = Signal<T>.generate(context: serialContext) { input in
			timerInput = input
		}
		var last: T? = nil
		return timerSignal.combine(initialState: (timer: nil, onDelete: nil), second: self, context: serialContext) { (state: inout (timer: Cancellable?, onDelete: OnDelete?), cr: EitherResult2<T, T>, n: SignalNext<T>) in
			if state.onDelete == nil {
				state.onDelete = OnDelete { last = nil }
			}
			switch cr {
			case .result2(.success(let v)):
				last = v
				state.timer = serialContext.singleTimer(interval: interval) {
					if let l = last {
						_ = timerInput?.send(value: l)
						last = nil
					}
				}
			case .result2(.failure(let e)):
				if flushOnClose, let l = last {
					_ = timerInput?.send(value: l)
					last = nil
				}
				n.send(error: e)
			case .result1(.success(let v)): n.send(value: v)
			case .result1(.failure(let e)): n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "throttleFirst"](http://reactivex.io/documentation/operators/sample.html)
	///
	/// - Note: this is largely the reverse of `debounce`.
	///
	/// - Parameters:
	///   - interval: the duration over which to drop values.
	///   - context: context where the timer will run
	/// - Returns: a signal where a timer is started when a value is received and emitted and further values received within that `interval` will be dropped.
	public func throttleFirst(interval: DispatchTimeInterval, context: Exec = .direct) -> Signal<T> {
		let timerQueue = context.serialized()
		var timer: Cancellable? = nil
		return transform(initialState: nil, context: timerQueue) { (cleanup: inout OnDelete?, r: Result<T>, n: SignalNext<T>) -> Void in
			cleanup = cleanup ?? OnDelete {
				timer = nil
			}
			
			switch r {
			case .failure(let e):
				n.send(error: e)
			case .success(let v) where timer == nil:
				n.send(value: v)
				timer = timerQueue.singleTimer(interval: interval) {
					timer = nil
				}
			default:
				break
			}
		}
	}
}

extension Signal where T: Hashable {
	/// Implementation of [Reactive X operator "distinct"](http://reactivex.io/documentation/operators/distinct.html)
	///
	/// - Returns: a signal where all values received are remembered and only values not previously received are emitted.
	public func distinct() -> Signal<T> {
		return transform(initialState: Set<T>()) { (previous: inout Set<T>, r: Result<T>, n: SignalNext<T>) -> Void in
			switch r {
			case .success(let v):
				if !previous.contains(v) {
					previous.insert(v)
					n.send(value: v)
				}
			case .failure(let e):
				n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "distinct"](http://reactivex.io/documentation/operators/distinct.html)
	///
	/// - Returns: a signal that emits the first value but then emits subsequent values only when they are different to the previous value.
	public func distinctUntilChanged() -> Signal<T> {
		return transform(initialState: nil) { (previous: inout T?, r: Result<T>, n: SignalNext<T>) -> Void in
			switch r {
			case .success(let v):
				if previous != v {
					previous = v
					n.send(value: v)
				}
			case .failure(let e):
				n.send(error: e)
			}
		}
	}
}

extension Signal {
	/// Implementation of [Reactive X operator "distinct"](http://reactivex.io/documentation/operators/distinct.html)
	///
	/// - Parameters:
	///   - context: the `Exec` where `comparator` will be evaluated (default: .direct).
	///   - comparator: a function taking two parameters (the previous and current value in the signal) which should return `false` to indicate the current value should be emitted.
	/// - Returns: a signal that emits the first value but then emits subsequent values only if the function `comparator` returns `false` when passed the previous and current values.
	public func distinctUntilChanged(context: Exec = .direct, comparator: @escaping (T, T) -> Bool) -> Signal<T> {
		return transform(initialState: nil) { (previous: inout T?, r: Result<T>, n: SignalNext<T>) -> Void in
			switch r {
			case .success(let v):
				if let p = previous, comparator(p, v) {
					// no action required
				} else {
					n.send(value: v)
				}
				previous = v
			case .failure(let e):
				n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "elementAt"](http://reactivex.io/documentation/operators/elementat.html)
	///
	/// - Parameter index: identifies the element to be emitted.
	/// - Returns: a signal that emits the zero-indexed element identified by `index` and then closes.
	public func elementAt(_ index: UInt) -> Signal<T> {
		return transform(initialState: 0, context: .direct) { (curr: inout UInt, r: Result<T>, n: SignalNext<T>) -> Void in
			switch r {
			case .success(let v) where curr == index:
				n.send(value: v)
				n.close()
			case .success:
				break
			case .failure(let e):
				n.send(error: e)
			}
			curr += 1
		}
	}
	
	/// Implementation of [Reactive X operator "filter"](http://reactivex.io/documentation/operators/filter.html)
	///
	/// - Parameters:
	///   - context: the `Exec` where `matching` will be evaluated (default: .direct).
	///   - matching: a function which is passed the current value and should return `true` to indicate the value should be emitted.
	/// - Returns: a signal that emits received values only if the function `matching` returns `true` when passed the value.
	public func filter(context: Exec = .direct, matching: @escaping (T) -> Bool) -> Signal<T> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<T>) -> Void in
			switch r {
			case .success(let v) where matching(v):
				n.send(value: v)
			case .success:
				break
			case .failure(let e):
				n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "ofType"](http://reactivex.io/documentation/operators/filter.html)
	///
	/// - Parameters:
	///   - type: values will be filtered to this type (NOTE: only the *static* type of this parameter is considered – if the runtime type is more specific, that will be ignored).
	/// - Returns: a signal that emits received values only if the value can be dynamically cast to the type `U`, specified statically by `type`.
	public func ofType<U>(_ type: U.Type) -> Signal<U> {
		return self.transform(initialState: 0) { (curr: inout Int, r: Result<T>, n: SignalNext<U>) -> Void in
			switch r {
			case .success(let v as U):
				n.send(value: v)
			case .success:
				break
			case .failure(let e):
				n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "first"](http://reactivex.io/documentation/operators/first.html)
	///
	/// - Parameters:
	///   - context: the `Exec` where `matching` will be evaluated (default: .direct).
	///   - matching: run for each value until it returns `true`
	/// - Returns: a signal that, when an error is received, emits the first value (if any) in the signal where `matching` returns `true` when invoked with the value, followed by the error.
	public func first(context: Exec = .direct, matching: @escaping (T) -> Bool = { _ in true }) -> Signal<T> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<T>) -> Void in
			switch r {
			case .success(let v) where matching(v):
				n.send(value: v)
				n.close()
			case .success:
				break
			case .failure(let e):
				n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "single"](http://reactivex.io/documentation/operators/first.html)
	///
	/// - Parameters:
	///   - context: the `Exec` where `matching` will be evaluated (default: .direct).
	///   - matching: run for each value
	/// - Returns: a signal that, if a single value in the sequence, when passed to `matching` returns `true`, then that value will be returned, followed by a SignalError.Closed when the input signal closes (otherwise a SignalError.Closed will be emitted without emitting any prior values).
	public func single(context: Exec = .direct, matching: @escaping (T) -> Bool = { _ in true }) -> Signal<T> {
		return transform(initialState: nil, context: context) { (state: inout (firstMatch: T, unique: Bool)?, r: Result<T>, n: SignalNext<T>) -> Void in
			switch r {
			case .success(let v) where matching(v):
				if let s = state {
					state = (firstMatch: s.firstMatch, unique: false)
				} else {
					state = (firstMatch: v, unique: true)
				}
			case .success:
				break
			case .failure:
				if let s = state, s.unique == true {
					n.send(value: s.firstMatch)
				}
				n.send(result: r)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "ignoreElements"](http://reactivex.io/documentation/operators/ignoreelements.html)
	///
	/// - Returns: a signal that emits the input error, when received, otherwise ignores all values.
	public func ignoreElements() -> Signal<T> {
		return transform { (r: Result<T>, n: SignalNext<T>) -> Void in
			if case .failure = r {
				n.send(result: r)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "ignoreElements"](http://reactivex.io/documentation/operators/ignoreelements.html)
	///
	/// - Returns: a signal that emits the input error, when received, otherwise ignores all values.
	public func ignoreElements<S: Sequence>(endWith: @escaping (Error) -> (S, Error)?) -> Signal<S.Iterator.Element> {
		return transform() { (r: Result<T>, n: SignalNext<S.Iterator.Element>) in
			switch r {
			case .success: break
			case .failure(let e):
				if let (sequence, err) = endWith(e) {
					sequence.forEach { n.send(value: $0) }
					n.send(error: err)
				} else {
					n.send(error: e)
				}
			}
		}
	}
	
	/// Implementation of [Reactive X operator "last"](http://reactivex.io/documentation/operators/last.html)
	///
	/// - Parameters:
	///   - context: the `Exec` where `matching` will be evaluated (default: .direct).
	///   - matching: run for each value
	/// - Returns: a signal that, when an error is received, emits the last value (if any) in the signal where `matching` returns `true` when invoked with the value, followed by the error.
	public func last(context: Exec = .direct, matching: @escaping (T) -> Bool = { _ in true }) -> Signal<T> {
		return transform(initialState: nil, context: context) { (last: inout T?, r: Result<T>, n: SignalNext<T>) -> Void in
			switch r {
			case .success(let v) where matching(v): last = v
			case .success: break
			case .failure:
				if let l = last {
					n.send(value: l)
				}
				n.send(result: r)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "sample"](http://reactivex.io/documentation/operators/sample.html)
	///
	/// - Parameter trigger: instructs the result to emit the last value from `self`
	/// - Returns: a signal that, when a value is received from `trigger`, emits the last value (if any) received from `self`.
	public func sample(_ trigger: Signal<()>) -> Signal<T> {
		return combine(initialState: nil, second: trigger, context: .direct) { (last: inout T?, c: EitherResult2<T, ()>, n: SignalNext<T>) -> Void in
			switch (c, last) {
			case (.result1(.success(let v)), _): last = v
			case (.result1(.failure(let e)), _): n.send(error: e)
			case (.result2(.success), .some(let l)): n.send(value: l)
			case (.result2(.success), _): break
			case (.result2(.failure(let e)), _): n.send(error: e)
			}
		}.continuous()
	}
	
	/// Implementation similar to [Reactive X operator "sample"](http://reactivex.io/documentation/operators/sample.html) except that the output also includes the value from the trigger signal.
	///
	/// - Parameter trigger: instructs the result to emit the last value from `self`
	/// - Returns: a signal that, when a value is received from `trigger`, emits the last value (if any) received from `self`.
	public func sampleCombine<U>(_ trigger: Signal<U>) -> Signal<(T, U)> {
		return combine(initialState: nil, second: trigger, context: .direct) { (last: inout T?, c: EitherResult2<T, U>, n: SignalNext<(T, U)>) -> Void in
			switch (c, last) {
			case (.result1(.success(let v)), _): last = v
			case (.result1(.failure(let e)), _): n.send(error: e)
			case (.result2(.success(let trigger)), .some(let l)): n.send(value: (l, trigger))
			case (.result2(.success), _): break
			case (.result2(.failure(let e)), _): n.send(error: e)
			}
		}.continuous()
	}
	
	/// Implementation of [Reactive X operator "skip"](http://reactivex.io/documentation/operators/skip.html)
	///
	/// - Parameter count: the number of values from the start of `self` to drop
	/// - Returns: a signal that drops `count` values from `self` then mirrors `self`.
	public func skip(_ count: Int) -> Signal<T> {
		return transform(initialState: 0) { (progressCount: inout Int, r: Result<T>, n: SignalNext<T>) -> Void in
			switch r {
			case .success(let v) where progressCount >= count: n.send(value: v)
			case .success: break
			case .failure(let e): n.send(error: e)
			}
			progressCount = progressCount + 1
		}
	}
	
	/// Implementation of [Reactive X operator "skipLast"](http://reactivex.io/documentation/operators/skiplast.html)
	///
	/// - Parameter count: the number of values from the end of `self` to drop
	/// - Returns: a signal that buffers `count` values from `self` then for each new value received from `self`, emits the oldest value in the buffer. When `self` closes, all remaining values in the buffer are discarded.
	public func skipLast(_ count: Int) -> Signal<T> {
		return transform(initialState: Array<T>()) { (buffer: inout Array<T>, r: Result<T>, n: SignalNext<T>) -> Void in
			switch r {
			case .success(let v):
				buffer.append(v)
				if buffer.count > count {
					n.send(value: buffer.removeFirst())
				}
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "skip"](http://reactivex.io/documentation/operators/skip.html)
	///
	/// - Parameter count: the number of values from the start of `self` to emit
	/// - Returns: a signal that emits `count` values from `self` then closes.
	public func take(_ count: Int) -> Signal<T> {
		return transform(initialState: 0) { (progressCount: inout Int, r: Result<T>, n: SignalNext<T>) -> Void in
			progressCount = progressCount + 1
			switch r {
			case .success(let v) where progressCount >= count:
				n.send(value: v)
				n.close()
			case .success(let v): n.send(value: v)
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "skipLast"](http://reactivex.io/documentation/operators/skiplast.html)
	///
	/// - Parameter count: the number of values from the end of `self` to emit
	/// - Returns: a signal that buffers `count` values from `self` then for each new value received from `self`, drops the oldest value in the buffer. When `self` closes, all values in the buffer are emitted, followed by the close.
	public func takeLast(_ count: Int) -> Signal<T> {
		return transform(initialState: Array<T>()) { (buffer: inout Array<T>, r: Result<T>, n: SignalNext<T>) -> Void in
			switch r {
			case .success(let v):
				buffer.append(v)
				if buffer.count > count {
					buffer.removeFirst()
				}
			case .failure(let e):
				for v in buffer {
					n.send(value: v)
				}
				n.send(error: e)
			}
		}
	}
}

extension Signal {
	/// - Note: the [Reactive X operators "And", "Then" and "When"](http://reactivex.io/documentation/operators/and-then-when.html) are considered unnecessary, given the slightly different implementation of `CwlSignal.Signal.zip` which produces tuples (rather than producing a non-structural type) and is hence equivalent to `and`+`then`.
}

extension Signal {
	/// Implementation of [Reactive X operator "combineLatest"](http://reactivex.io/documentation/operators/combinelatest.html) for two observed signals.
	///
	/// - Parameters:
	///   - second: an observed signal.
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: invoked with the most recent values of the observed signals (or nil if a signal has not yet emitted a value) when any of the observed signals emits a value
	/// - Returns: a signal that emits the values from the processor and closes when any of the observed signals closes
	public func combineLatest<U, V>(second: Signal<U>, context: Exec = .direct, _ processor: @escaping (T, U) -> V) -> Signal<V> {
		return combine(initialState: (nil, nil), second: second, context: context) { (state: inout (T?, U?), r: EitherResult2<T, U>, n: SignalNext<V>) -> Void in
			switch r {
			case .result1(.success(let v)): state = (v, state.1)
			case .result2(.success(let v)): state = (state.0, v)
			case .result1(.failure(let e)): n.send(error: e); return
			case .result2(.failure(let e)): n.send(error: e); return
			}
			if let v0 = state.0, let v1 = state.1 {
				n.send(value: processor(v0, v1))
			}
		}
	}
	
	/// Implementation of [Reactive X operator "combineLatest"](http://reactivex.io/documentation/operators/combinelatest.html) for three observed signals.
	///
	/// - Parameters:
	///   - second: an observed signal.
	///   - third: an observed signal.
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: invoked with the most recent values of the observed signals (or nil if a signal has not yet emitted a value) when any of the observed signals emits a value
	/// - Returns: a signal that emits the values from the processor and closes when any of the observed signals closes
	public func combineLatest<U, V, W>(second: Signal<U>, third: Signal<V>, context: Exec = .direct, _ processor: @escaping (T, U, V) -> W) -> Signal<W> {
		return combine(initialState: (nil, nil, nil), second: second, third: third, context: context) { (state: inout (T?, U?, V?), r: EitherResult3<T, U, V>, n: SignalNext<W>) -> Void in
			switch r {
			case .result1(.success(let v)): state = (v, state.1, state.2)
			case .result2(.success(let v)): state = (state.0, v, state.2)
			case .result3(.success(let v)): state = (state.0, state.1, v)
			case .result1(.failure(let e)): n.send(error: e); return
			case .result2(.failure(let e)): n.send(error: e); return
			case .result3(.failure(let e)): n.send(error: e); return
			}
			if let v0 = state.0, let v1 = state.1, let v2 = state.2 {
				n.send(value: processor(v0, v1, v2))
			}
		}
	}
	
	/// Implementation of [Reactive X operator "combineLatest"](http://reactivex.io/documentation/operators/combinelatest.html) for four observed signals.
	///
	/// - Note: support for multiple listeners and reactivation is determined by the specified `behavior`.
	///
	/// - Parameters:
	///   - second: an observed signal.
	///   - third: an observed signal.
	///   - fourth: an observed signal.
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: invoked with the most recent values of the observed signals (or nil if a signal has not yet emitted a value) when any of the observed signals emits a value
	/// - Returns: a signal that emits the values from the processor and closes when any of the observed signals closes
	public func combineLatest<U, V, W, X>(second: Signal<U>, third: Signal<V>, fourth: Signal<W>, context: Exec = .direct, _ processor: @escaping (T, U, V, W) -> X) -> Signal<X> {
		return combine(initialState: (nil, nil, nil, nil), second: second, third: third, fourth: fourth, context: context) { (state: inout (T?, U?, V?, W?), r: EitherResult4<T, U, V, W>, n: SignalNext<X>) -> Void in
			switch r {
			case .result1(.success(let v)): state = (v, state.1, state.2, state.3)
			case .result2(.success(let v)): state = (state.0, v, state.2, state.3)
			case .result3(.success(let v)): state = (state.0, state.1, v, state.3)
			case .result4(.success(let v)): state = (state.0, state.1, state.2, v)
			case .result1(.failure(let e)): n.send(error: e); return
			case .result2(.failure(let e)): n.send(error: e); return
			case .result3(.failure(let e)): n.send(error: e); return
			case .result4(.failure(let e)): n.send(error: e); return
			}
			if let v0 = state.0, let v1 = state.1, let v2 = state.2, let v3 = state.3 {
				n.send(value: processor(v0, v1, v2, v3))
			}
		}
	}
	
	/// Implementation of [Reactive X operator "combineLatest"](http://reactivex.io/documentation/operators/combinelatest.html) for five observed signals.
	///
	/// - Note: support for multiple listeners and reactivation is determined by the specified `behavior`.
	///
	/// - Parameters:
	///   - second: an observed signal.
	///   - third: an observed signal.
	///   - fourth: an observed signal.
	///   - fifth: an observed signal.
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: invoked with the most recent values of the observed signals (or nil if a signal has not yet emitted a value) when any of the observed signals emits a value
	/// - Returns: a signal that emits the values from the processor and closes when any of the observed signals closes
	public func combineLatest<U, V, W, X, Y>(second: Signal<U>, third: Signal<V>, fourth: Signal<W>, fifth: Signal<X>, context: Exec = .direct, _ processor: @escaping (T, U, V, W, X) -> Y) -> Signal<Y> {
		return combine(initialState: (nil, nil, nil, nil, nil), second: second, third: third, fourth: fourth, fifth: fifth, context: context) { (state: inout (T?, U?, V?, W?, X?), r: EitherResult5<T, U, V, W, X>, n: SignalNext<Y>) -> Void in
			switch r {
			case .result1(.success(let v)): state = (v, state.1, state.2, state.3, state.4)
			case .result2(.success(let v)): state = (state.0, v, state.2, state.3, state.4)
			case .result3(.success(let v)): state = (state.0, state.1, v, state.3, state.4)
			case .result4(.success(let v)): state = (state.0, state.1, state.2, v, state.4)
			case .result5(.success(let v)): state = (state.0, state.1, state.2, state.3, v)
			case .result1(.failure(let e)): n.send(error: e); return
			case .result2(.failure(let e)): n.send(error: e); return
			case .result3(.failure(let e)): n.send(error: e); return
			case .result4(.failure(let e)): n.send(error: e); return
			case .result5(.failure(let e)): n.send(error: e); return
			}
			if let v0 = state.0, let v1 = state.1, let v2 = state.2, let v3 = state.3, let v4 = state.4 {
				n.send(value: processor(v0, v1, v2, v3, v4))
			}
		}
	}
	
	/// Implementation of [Reactive X operator "join"](http://reactivex.io/documentation/operators/join.html)
	///
	/// - Note: support for multiple listeners and reactivation is determined by the specified `behavior`.
	///
	/// - Parameters:
	///   - withRight: an observed signal
	///   - leftEnd: function invoked when a value is received from `self`. The resulting signal is observed and the time until signal close is treated as a duration "window" that started with the received `self` value.
	///   - rightEnd: function invoked when a value is received from `right`. The resulting signal is observed and the time until signal close is treated as a duration "window" that started with the received `right` value.
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: invoked with the corresponding `left` and `right` values when a `left` value is emitted during a `right`->`rightEnd` window or a `right` value is received during a `left`->`leftEnd` window
	/// - Returns: a signal that emits the values from the processor and closes when any of the last of the observed windows closes.
	public func join<U, V, W, X>(withRight: Signal<U>, leftEnd: @escaping (T) -> Signal<V>, rightEnd: @escaping (U) -> Signal<W>, context: Exec = .direct, _ processor: @escaping ((T, U)) -> X) -> Signal<X> {
		let leftDurations = valueDurations(duration: { t in leftEnd(t).takeWhile { _ in false } })
		let rightDurations = withRight.valueDurations(duration: { u in rightEnd(u).takeWhile { _ in false } })
		let a = leftDurations.combine(initialState: ([Int: T](), [Int: U]()), second: rightDurations) { (state: inout (activeLeft: [Int: T], activeRight: [Int: U]), cr: EitherResult2<(Int, T?), (Int, U?)>, next: SignalNext<(T, U)>) in
			switch cr {
			case .result1(.success(let leftIndex, .some(let leftValue))):
				state.activeLeft[leftIndex] = leftValue
				state.activeRight.sorted { $0.0 < $1.0 }.forEach { tuple in next.send(value: (leftValue, tuple.value)) }
			case .result2(.success(let rightIndex, .some(let rightValue))):
				state.activeRight[rightIndex] = rightValue
				state.activeLeft.sorted { $0.0 < $1.0 }.forEach { tuple in next.send(value: (tuple.value, rightValue)) }
			case .result1(.success(let leftIndex, .none)): state.activeLeft.removeValue(forKey: leftIndex)
			case .result2(.success(let rightIndex, .none)): state.activeRight.removeValue(forKey: rightIndex)
			default: next.close()
			}
		}
		return a.map(context: context, processor)
	}
	
	/// Implementation of [Reactive X operator "groupJoin"](http://reactivex.io/documentation/operators/join.html)
	///
	/// - Parameters:
	///   - withRight: an observed signal.
	///   - leftEnd: function invoked when a value is received from `self`. The resulting signal is observed and the time until signal close is treated as a duration "window" that started with the received `self` value.
	///   - rightEnd: function invoked when a value is received from `right`. The resulting signal is observed and the time until signal close is treated as a duration "window" that started with the received `right` value.
	///   - context: the `Exec` where `processor` will be evaluated (default: .direct).
	///   - processor: when a `left` value is received, this function is invoked with the `left` value and a `Signal` that will emit all the `right` values encountered until the `left`->`leftEnd` window closes. The value returned by this function will be emitted as part of the `Signal` returned from `groupJoin`.
	/// - Returns: a signal that emits the values from the processor and closes when any of the last of the observed windows closes.
	public func groupJoin<U, V, W, X>(withRight: Signal<U>, leftEnd: @escaping (T) -> Signal<V>, rightEnd: @escaping (U) -> Signal<W>, context: Exec = .direct, _ processor: @escaping ((T, Signal<U>)) -> X) -> Signal<X> {
		let leftDurations = valueDurations(duration: { u in leftEnd(u).takeWhile { _ in false } })
		let rightDurations = withRight.valueDurations(duration: { u in rightEnd(u).takeWhile { _ in false } })
		return leftDurations.combine(initialState: ([Int: SignalInput<U>](), [Int: U]()), second: rightDurations) { (state: inout (activeLeft: [Int: SignalInput<U>], activeRight: [Int: U]), cr: EitherResult2<(Int, T?), (Int, U?)>, next: SignalNext<(T, Signal<U>)>) in
			switch cr {
			case .result1(.success(let leftIndex, .some(let leftValue))):
				let (li, ls) = Signal<U>.create()
				state.activeLeft[leftIndex] = li
				next.send(value: (leftValue, ls))
				state.activeRight.sorted { $0.0 < $1.0 }.forEach { tuple in li.send(value: tuple.value) }
			case .result2(.success(let rightIndex, .some(let rightValue))):
				state.activeRight[rightIndex] = rightValue
				state.activeLeft.sorted { $0.0 < $1.0 }.forEach { tuple in tuple.value.send(value: rightValue) }
			case .result1(.success(let leftIndex, .none)):
				_ = state.activeLeft[leftIndex]?.close()
				state.activeLeft.removeValue(forKey: leftIndex)
			case .result2(.success(let rightIndex, .none)):
				state.activeRight.removeValue(forKey: rightIndex)
			default: next.close()
			}
		}.map(context: context, processor)
	}
	
	/// Implementation of [Reactive X operator "merge"](http://reactivex.io/documentation/operators/merge.html) where the output closes only when the last source closes.
	///
	/// NOTE: the signal closes as `SignalError.cancelled` when the last output closes. For other closing semantics, use `Signal.mergSetAndSignal` instead.
	///
	/// - Parameter sources: an `Array` where `signal` is merged into the result.
	/// - Returns: a signal that emits every value from every `sources` input `signal`.
	public static func merge<S: Sequence>(_ sources: S) -> Signal<T> where S.Iterator.Element == Signal<T> {
		let (_, signal) = Signal<T>.createMergeSet(sources)
		return signal
	}
	
	/// Implementation of [Reactive X operator "merge"](http://reactivex.io/documentation/operators/merge.html) where the output closes only when the last source closes.
	///
	/// NOTE: the signal closes as `SignalError.cancelled` when the last output closes. For other closing semantics, use `Signal.mergSetAndSignal` instead.
	///
	/// - Parameter sources: a variable parameter list of `Signal<T>` instances that are merged with `self` to form the result.
	/// - Returns: a signal that emits every value from every `sources` input `signal`.
	public func mergeWith(_ sources: Signal<T>...) -> Signal<T> {
		let (mergeSet, signal) = Signal<T>.createMergeSet()
		try! mergeSet.add(self, closePropagation: .errors)
		for s in sources {
			try! mergeSet.add(s, closePropagation: .errors)
		}
		return signal
	}
	
	/// Implementation of [Reactive X operator "startWith"](http://reactivex.io/documentation/operators/startwith.html)
	///
	/// - Parameter sequence: a sequence of values.
	/// - Returns: a signal that emits every value from `sequence` on activation and then mirrors `self`.
	public func startWith<S: Sequence>(_ sequence: S) -> Signal<T> where S.Iterator.Element == T {
		return Signal.preclosed(values: sequence).combine(second: self) { (r: EitherResult2<T, T>, n: SignalNext<T>) in
			switch r {
			case .result1(.success(let v)): n.send(value: v)
			case .result1(.failure): break
			case .result2(.success(let v)): n.send(value: v)
			case .result2(.failure(let e)): n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "endWith"](http://reactivex.io/documentation/operators/endwith.html)
	///
	/// - Returns: a signal that emits every value from `sequence` on activation and then mirrors `self`.
	public func endWith<U: Sequence>(_ sequence: U, conditional: @escaping (Error) -> Error? = { e in e }) -> Signal<T> where U.Iterator.Element == T {
		return transform() { (r: Result<T>, n: SignalNext<T>) in
			switch r {
			case .success(let v): n.send(value: v)
			case .failure(let e):
				if let newEnd = conditional(e) {
					sequence.forEach { n.send(value: $0) }
					n.send(error: newEnd)
				} else {
					n.send(error: e)
				}
			}
		}
	}
	
	/// Implementation of [Reactive X operator "switch"](http://reactivex.io/documentation/operators/switch.html)
	///
	/// See also: `flatMapLatest` (emits values from the latest `Signal` to start emitting)
	///
	/// NOTE: ideally, this would not be a static function but a "same type" conditional extension. In a future Swift release this will probably change.
	///
	/// - Parameter signal: each of the inner signals emitted by this outer signal is observed, with the most recent signal emitted from the result
	/// - Returns: a signal that emits the values from the latest `Signal` emitted by `signal`
	public static func switchLatest<T>(_ signal: Signal<Signal<T>>) -> Signal<T> {
		return signal.transformFlatten(initialState: nil, closePropagation: .errors) { (latest: inout Signal<T>?, next: Signal<T>, mergeSet: SignalMergeSet<T>) in
			if let l = latest {
				mergeSet.remove(l)
			}
			latest = next
			_ = try? mergeSet.add(next, closePropagation: .errors, removeOnDeactivate: true)
		}
	}
	
	/// Implementation of [Reactive X operator "zip"](http://reactivex.io/documentation/operators/zip.html)
	///
	/// - Parameter second: another `Signal`
	/// - Returns: a signal that emits the values from `self`, paired with corresponding value from `with`.
	public func zip<U>(second: Signal<U>) -> Signal<(T, U)> {
		return combine(initialState: (Array<T>(), Array<U>(), false, false), second: second) { (queues: inout (first: Array<T>, second: Array<U>, firstClosed: Bool, secondClosed: Bool), r: EitherResult2<T, U>, n: SignalNext<(T, U)>) in
			switch (r, queues.first.first, queues.second.first) {
			case (.result1(.success(let first)), _, .some(let second)):
				n.send(value: (first, second))
				queues.second.removeFirst()
				if (queues.second.isEmpty && queues.secondClosed) {
					n.close()
				}
			case (.result1(.success(let first)), _, _):
				queues.first.append(first)
			case (.result1(.failure(let e)), _, _):
				if queues.first.isEmpty || (queues.second.isEmpty && queues.secondClosed) {
					n.send(error: e)
				} else {
					queues.firstClosed = true
				}
				
			case (.result2(.success(let second)), .some(let first), _):
				n.send(value: (first, second))
				queues.first.removeFirst()
				if (queues.first.isEmpty && queues.firstClosed) {
					n.close()
				}
			case (.result2(.success(let second)), _, _):
				queues.second.append(second)
			case (.result2(.failure(let e)), _, _):
				if queues.second.isEmpty || (queues.first.isEmpty && queues.firstClosed) {
					n.send(error: e)
				} else {
					queues.secondClosed = true
				}
			}
		}
	}
	
	/// Implementation of [Reactive X operator "zip"](http://reactivex.io/documentation/operators/zip.html)
	///
	/// - Parameters:
	///   - second: another `Signal`
	///   - third: another `Signal`
	/// - Returns: a signal that emits the values from `self`, paired with corresponding value from `second` and `third`.
	public func zip<U, V>(second: Signal<U>, third: Signal<V>) -> Signal<(T, U, V)> {
		return combine(initialState: (Array<T>(), Array<U>(), Array<V>(), false, false, false), second: second, third: third) { (queues: inout (first: Array<T>, second: Array<U>, third: Array<V>, firstClosed: Bool, secondClosed: Bool, thirdClosed: Bool), r: EitherResult3<T, U, V>, n: SignalNext<(T, U, V)>) in
			switch (r, queues.first.first, queues.second.first, queues.third.first) {
			case (.result1(.success(let first)), _, .some(let second), .some(let third)):
				n.send(value: (first, second, third))
				queues.second.removeFirst()
				queues.third.removeFirst()
				if (queues.second.isEmpty && queues.secondClosed) || (queues.third.isEmpty && queues.thirdClosed) {
					n.close()
				}
			case (.result1(.success(let first)), _, _, _):
				queues.first.append(first)
			case (.result1(.failure(let e)), _, _, _):
				if queues.first.isEmpty || (queues.second.isEmpty && queues.secondClosed) || (queues.third.isEmpty && queues.thirdClosed) {
					n.send(error: e)
				} else {
					queues.firstClosed = true
				}
				
			case (.result2(.success(let second)), .some(let first), _, .some(let third)):
				n.send(value: (first, second, third))
				queues.first.removeFirst()
				queues.third.removeFirst()
				if (queues.first.isEmpty && queues.firstClosed) || (queues.third.isEmpty && queues.thirdClosed) {
					n.close()
				}
			case (.result2(.success(let second)), _, _, _):
				queues.second.append(second)
			case (.result2(.failure(let e)), _, _, _):
				if queues.second.isEmpty || (queues.first.isEmpty && queues.firstClosed) || (queues.third.isEmpty && queues.thirdClosed) {
					n.send(error: e)
				} else {
					queues.secondClosed = true
				}
				
			case (.result3(.success(let third)), .some(let first), .some(let second), _):
				n.send(value: (first, second, third))
				queues.first.removeFirst()
				queues.second.removeFirst()
				if (queues.first.isEmpty && queues.firstClosed) || (queues.second.isEmpty && queues.secondClosed) {
					n.close()
				}
			case (.result3(.success(let third)), _, _, _):
				queues.third.append(third)
			case (.result3(.failure(let e)), _, _, _):
				if queues.third.isEmpty || (queues.first.isEmpty && queues.firstClosed) || (queues.second.isEmpty && queues.secondClosed) {
					n.send(error: e)
				} else {
					queues.thirdClosed = true
				}
			}
		}
	}
	
	/// Implementation of [Reactive X operator "zip"](http://reactivex.io/documentation/operators/zip.html)
	///
	/// - Parameters:
	///   - second: another `Signal`
	///   - third: another `Signal`
	///   - fourth: another `Signal`
	/// - Returns: a signal that emits the values from `self`, paired with corresponding value from `second`,`third` and `fourth`.
	public func zip<U, V, W>(second: Signal<U>, third: Signal<V>, fourth: Signal<W>) -> Signal<(T, U, V, W)> {
		return combine(initialState: (Array<T>(), Array<U>(), Array<V>(), Array<W>(), false, false, false, false), second: second, third: third, fourth: fourth) { (queues: inout (first: Array<T>, second: Array<U>, third: Array<V>, fourth: Array<W>, firstClosed: Bool, secondClosed: Bool, thirdClosed: Bool, fourthClosed: Bool), r: EitherResult4<T, U, V, W>, n: SignalNext<(T, U, V, W)>) in
			switch (r, queues.first.first, queues.second.first, queues.third.first, queues.fourth.first) {
			case (.result1(.success(let first)), _, .some(let second), .some(let third), .some(let fourth)):
				n.send(value: (first, second, third, fourth))
				queues.second.removeFirst()
				queues.third.removeFirst()
				queues.fourth.removeFirst()
				if (queues.second.isEmpty && queues.secondClosed) || (queues.third.isEmpty && queues.thirdClosed) || (queues.fourth.isEmpty && queues.fourthClosed) {
					n.close()
				}
			case (.result1(.success(let first)), _, _, _, _):
				queues.first.append(first)
			case (.result1(.failure(let e)), _, _, _, _):
				if queues.first.isEmpty || (queues.second.isEmpty && queues.secondClosed) || (queues.third.isEmpty && queues.thirdClosed) || (queues.fourth.isEmpty && queues.fourthClosed) {
					n.send(error: e)
				} else {
					queues.firstClosed = true
				}
				
			case (.result2(.success(let second)), .some(let first), _, .some(let third), .some(let fourth)):
				n.send(value: (first, second, third, fourth))
				queues.first.removeFirst()
				queues.third.removeFirst()
				queues.fourth.removeFirst()
				if (queues.first.isEmpty && queues.firstClosed) || (queues.third.isEmpty && queues.thirdClosed) || (queues.fourth.isEmpty && queues.fourthClosed) {
					n.close()
				}
			case (.result2(.success(let second)), _, _, _, _):
				queues.second.append(second)
			case (.result2(.failure(let e)), _, _, _, _):
				if queues.second.isEmpty || (queues.first.isEmpty && queues.firstClosed) || (queues.third.isEmpty && queues.thirdClosed) || (queues.fourth.isEmpty && queues.fourthClosed) {
					n.send(error: e)
				} else {
					queues.secondClosed = true
				}
				
			case (.result3(.success(let third)), .some(let first), .some(let second), _, .some(let fourth)):
				n.send(value: (first, second, third, fourth))
				queues.first.removeFirst()
				queues.second.removeFirst()
				queues.fourth.removeFirst()
				if (queues.first.isEmpty && queues.firstClosed) || (queues.second.isEmpty && queues.secondClosed) || (queues.fourth.isEmpty && queues.fourthClosed) {
					n.close()
				}
			case (.result3(.success(let third)), _, _, _, _):
				queues.third.append(third)
			case (.result3(.failure(let e)), _, _, _, _):
				if queues.third.isEmpty || (queues.first.isEmpty && queues.firstClosed) || (queues.second.isEmpty && queues.secondClosed) || (queues.fourth.isEmpty && queues.fourthClosed) {
					n.send(error: e)
				} else {
					queues.thirdClosed = true
				}
				
			case (.result4(.success(let fourth)), .some(let first), .some(let second), .some(let third), _):
				n.send(value: (first, second, third, fourth))
				queues.first.removeFirst()
				queues.second.removeFirst()
				queues.third.removeFirst()
				if (queues.first.isEmpty && queues.firstClosed) || (queues.second.isEmpty && queues.secondClosed) || (queues.third.isEmpty && queues.thirdClosed) {
					n.close()
				}
			case (.result4(.success(let fourth)), _, _, _, _):
				queues.fourth.append(fourth)
			case (.result4(.failure(let e)), _, _, _, _):
				if queues.fourth.isEmpty || (queues.first.isEmpty && queues.firstClosed) || (queues.second.isEmpty && queues.secondClosed) || (queues.third.isEmpty && queues.thirdClosed) {
					n.send(error: e)
				} else {
					queues.fourthClosed = true
				}
			}
		}
	}
	
	/// Implementation of [Reactive X operator "zip"](http://reactivex.io/documentation/operators/zip.html)
	///
	/// - Parameters:
	///   - second: another `Signal`
	///   - third: another `Signal`
	///   - fourth: another `Signal`
	///   - fifth: another `Signal`
	/// - Returns: a signal that emits the values from `self`, paired with corresponding value from `second`,`third`, `fourth` and `fifth`.
	public func zip<U, V, W, X>(second: Signal<U>, third: Signal<V>, fourth: Signal<W>, fifth: Signal<X>) -> Signal<(T, U, V, W, X)> {
		return combine(initialState: (Array<T>(), Array<U>(), Array<V>(), Array<W>(), Array<X>(), false, false, false, false, false), second: second, third: third, fourth: fourth, fifth: fifth) { (queues: inout (first: Array<T>, second: Array<U>, third: Array<V>, fourth: Array<W>, fifth: Array<X>, firstClosed: Bool, secondClosed: Bool, thirdClosed: Bool, fourthClosed: Bool, fifthClosed: Bool), r: EitherResult5<T, U, V, W, X>, n: SignalNext<(T, U, V, W, X)>) in
			switch (r, queues.first.first, queues.second.first, queues.third.first, queues.fourth.first, queues.fifth.first) {
			case (.result1(.success(let first)), _, .some(let second), .some(let third), .some(let fourth), .some(let fifth)):
				n.send(value: (first, second, third, fourth, fifth))
				queues.second.removeFirst()
				queues.third.removeFirst()
				queues.fourth.removeFirst()
				queues.fifth.removeFirst()
				if (queues.second.isEmpty && queues.secondClosed) || (queues.third.isEmpty && queues.thirdClosed) || (queues.fourth.isEmpty && queues.fourthClosed) || (queues.fifth.isEmpty && queues.fifthClosed) {
					n.close()
				}
			case (.result1(.success(let first)), _, _, _, _, _):
				queues.first.append(first)
			case (.result1(.failure(let e)), _, _, _, _, _):
				if queues.first.isEmpty || (queues.second.isEmpty && queues.secondClosed) || (queues.third.isEmpty && queues.thirdClosed) || (queues.fourth.isEmpty && queues.fourthClosed) || (queues.fifth.isEmpty && queues.fifthClosed) {
					n.send(error: e)
				} else {
					queues.firstClosed = true
				}
				
			case (.result2(.success(let second)), .some(let first), _, .some(let third), .some(let fourth), .some(let fifth)):
				n.send(value: (first, second, third, fourth, fifth))
				queues.first.removeFirst()
				queues.third.removeFirst()
				queues.fourth.removeFirst()
				queues.fifth.removeFirst()
				if (queues.first.isEmpty && queues.firstClosed) || (queues.third.isEmpty && queues.thirdClosed) || (queues.fourth.isEmpty && queues.fourthClosed) || (queues.fifth.isEmpty && queues.fifthClosed) {
					n.close()
				}
			case (.result2(.success(let second)), _, _, _, _, _):
				queues.second.append(second)
			case (.result2(.failure(let e)), _, _, _, _, _):
				if queues.second.isEmpty || (queues.first.isEmpty && queues.firstClosed) || (queues.third.isEmpty && queues.thirdClosed) || (queues.fourth.isEmpty && queues.fourthClosed) || (queues.fifth.isEmpty && queues.fifthClosed) {
					n.send(error: e)
				} else {
					queues.secondClosed = true
				}
				
			case (.result3(.success(let third)), .some(let first), .some(let second), _, .some(let fourth), .some(let fifth)):
				n.send(value: (first, second, third, fourth, fifth))
				queues.first.removeFirst()
				queues.second.removeFirst()
				queues.fourth.removeFirst()
				queues.fifth.removeFirst()
				if (queues.first.isEmpty && queues.firstClosed) || (queues.second.isEmpty && queues.secondClosed) || (queues.fourth.isEmpty && queues.fourthClosed) || (queues.fifth.isEmpty && queues.fifthClosed) {
					n.close()
				}
			case (.result3(.success(let third)), _, _, _, _, _):
				queues.third.append(third)
			case (.result3(.failure(let e)), _, _, _, _, _):
				if queues.third.isEmpty || (queues.first.isEmpty && queues.firstClosed) || (queues.second.isEmpty && queues.secondClosed) || (queues.fourth.isEmpty && queues.fourthClosed) || (queues.fifth.isEmpty && queues.fifthClosed) {
					n.send(error: e)
				} else {
					queues.thirdClosed = true
				}
				
			case (.result4(.success(let fourth)), .some(let first), .some(let second), .some(let third), _, .some(let fifth)):
				n.send(value: (first, second, third, fourth, fifth))
				queues.first.removeFirst()
				queues.second.removeFirst()
				queues.third.removeFirst()
				queues.fifth.removeFirst()
				if (queues.first.isEmpty && queues.firstClosed) || (queues.second.isEmpty && queues.secondClosed) || (queues.third.isEmpty && queues.thirdClosed) || (queues.fifth.isEmpty && queues.fifthClosed) {
					n.close()
				}
			case (.result4(.success(let fourth)), _, _, _, _, _):
				queues.fourth.append(fourth)
			case (.result4(.failure(let e)), _, _, _, _, _):
				if queues.fourth.isEmpty || (queues.first.isEmpty && queues.firstClosed) || (queues.second.isEmpty && queues.secondClosed) || (queues.third.isEmpty && queues.thirdClosed) || (queues.fifth.isEmpty && queues.fifthClosed) {
					n.send(error: e)
				} else {
					queues.fourthClosed = true
				}
				
			case (.result5(.success(let fifth)), .some(let first), .some(let second), .some(let third), .some(let fourth), _):
				n.send(value: (first, second, third, fourth, fifth))
				queues.first.removeFirst()
				queues.second.removeFirst()
				queues.third.removeFirst()
				queues.fourth.removeFirst()
				if (queues.first.isEmpty && queues.firstClosed) || (queues.second.isEmpty && queues.secondClosed) || (queues.third.isEmpty && queues.thirdClosed) || (queues.fourth.isEmpty && queues.fourthClosed) {
					n.close()
				}
			case (.result5(.success(let fifth)), _, _, _, _, _):
				queues.fifth.append(fifth)
			case (.result5(.failure(let e)), _, _, _, _, _):
				if queues.fifth.isEmpty || (queues.first.isEmpty && queues.firstClosed) || (queues.second.isEmpty && queues.secondClosed) || (queues.third.isEmpty && queues.thirdClosed) || (queues.fourth.isEmpty && queues.fourthClosed) {
					n.send(error: e)
				} else {
					queues.fifthClosed = true
				}
			}
		}
	}
	
	/// Implementation of [Reactive X operator "catch"](http://reactivex.io/documentation/operators/catch.html), returning a sequence on error in `self`.
	///
	/// - Parameters:
	///   - context: context where `recover` will run
	///   - recover: a function that, when passed the `ErrorType` that closed `self`, returns a sequence of values and an `ErrorType` that should be emitted instead of the error that `self` emitted.
	/// - Returns: a signal that emits the values from `self` until an error is received and then emits the values from `recover` and then emits the error from `recover`.
	public func catchError<S: Sequence>(context: Exec = .direct, recover: @escaping (Error) -> (S, Error)) -> Signal<T> where S.Iterator.Element == T {
		return transform(context: context) { (r: Result<T>, n: SignalNext<T>) in
			switch r {
			case .success(let v): n.send(value: v)
			case .failure(let e):
				let (sequence, error) = recover(e)
				sequence.forEach { n.send(value: $0) }
				n.send(error: error)
			}
		}
	}
}

// Essentially a closure type used by `catchError`, defined as a separate class so the function can reference itself
private class CatchErrorRecovery<T> {
	fileprivate let recover: (Error) -> Signal<T>?
	fileprivate init(recover: @escaping (Error) -> Signal<T>?) {
		self.recover = recover
	}
	fileprivate func catchErrorRejoin(j: SignalJunction<T>, e: Error, i: SignalInput<T>) {
		if let s = recover(e) {
			do {
				let f: (SignalJunction<T>, Error, SignalInput<T>) -> () = self.catchErrorRejoin
				try s.join(to: i, onError: f)
			} catch {
				i.send(error: error)
			}
		} else {
			i.send(error: e)
		}
	}
}

// Essentially a closure type used by `retry`, defined as a separate class so the function can reference itself
private class RetryRecovery<U> {
	fileprivate let shouldRetry: (inout U, Error) -> DispatchTimeInterval?
	fileprivate var state: U
	fileprivate let context: Exec
	fileprivate var timer: Cancellable? = nil
	fileprivate init(shouldRetry: @escaping (inout U, Error) -> DispatchTimeInterval?, state: U, context: Exec) {
		self.shouldRetry = shouldRetry
		self.state = state
		self.context = context
	}
	fileprivate func retryRejoin<T>(j: SignalJunction<T>, e: Error, i: SignalInput<T>) {
		if let t = shouldRetry(&state, e) {
			timer = context.singleTimer(interval: t) {
				do {
					try j.join(to: i, onError: self.retryRejoin)
				} catch {
					i.send(error: error)
				}
			}
		} else {
			i.send(error: e)
		}
	}
}

extension Signal {
	/// Implementation of [Reactive X operator "catch"](http://reactivex.io/documentation/operators/catch.html), returning a `Signal` on error in `self`.
	///
	/// - Parameters:
	///   - context: context where `recover` will run
	///   - recover: a function that, when passed the `ErrorType` that closed `self`, optionally returns a new signal.
	/// - Returns: a signal that emits the values from `self` until an error is received and then, if `recover` returns non-`nil` emits the values from `recover` and then emits the error from `recover`, otherwise if `recover` returns `nil`, emits the `ErrorType` from `self`.
	public func catchError(context: Exec = .direct, recover: @escaping (Error) -> Signal<T>?) -> Signal<T> {
		let (input, signal) = Signal<T>.create()
		do {
			try join(to: input, onError: CatchErrorRecovery(recover: recover).catchErrorRejoin)
		} catch {
			input.send(error: error)
		}
		return signal
	}
	
	/// Implementation of [Reactive X operator "retry"](http://reactivex.io/documentation/operators/retry.html) where the choice to retry and the delay between retries is controlled by a function.
	///
	/// - Note: a ReactiveX "resubscribe" is interpreted as a disconnect and reconnect, which will trigger reactivation iff (if and only if) the preceding nodes have behavior that supports that.
	///
	/// - Parameters:
	///   - initialState:  a mutable state value that will be passed into `shouldRetry`.
	///   - context: the `Exec` where timed reconnection will occcur (default: .Default).
	///   - shouldRetry: a function that, when passed the current state value and the `ErrorType` that closed `self`, returns an `Optional<Double>`.
	/// - Returns: a signal that emits the values from `self` until an error is received and then, if `shouldRetry` returns non-`nil`, disconnects from `self`, delays by the number of seconds returned from `shouldRetry`, and reconnects to `self` (triggering re-activation), otherwise if `shouldRetry` returns `nil`, emits the `ErrorType` from `self`. If the number of seconds is `0`, the reconnect is synchronous, otherwise it will occur in `context` using `invokeAsync`.
	public func retry<U>(_ initialState: U, context: Exec = .direct, shouldRetry: @escaping (inout U, Error) -> DispatchTimeInterval?) -> Signal<T> {
		let (input, signal) = Signal<T>.create()
		do {
			try join(to: input, onError: RetryRecovery(shouldRetry: shouldRetry, state: initialState, context: context).retryRejoin)
		} catch {
			input.send(error: error)
		}
		return signal
	}
	
	/// Implementation of [Reactive X operator "retry"](http://reactivex.io/documentation/operators/retry.html) where retries occur until the error is not `SignalError.Closed` or `count` number of retries has occurred.
	///
	/// - Note: a ReactiveX "resubscribe" is interpreted as a disconnect and reconnect, which will trigger reactivation iff the preceding nodes have behavior that supports that.
	///
	/// - Parameters:
	///   - count: the maximum number of retries
	///   - delayInterval: the number of seconds between retries
	///   - context: the `Exec` where timed reconnection will occcur (default: .Default).
	/// - Returns: a signal that emits the values from `self` until an error is received and then, if fewer than `count` retries have occurred, disconnects from `self`, delays by `delaySeconds` and reconnects to `self` (triggering re-activation), otherwise if `count` retries have occurred, emits the `ErrorType` from `self`. If the number of seconds is `0`, the reconnect is synchronous, otherwise it will occur in `context` using `invokeAsync`.
	public func retry(count: Int, delayInterval: DispatchTimeInterval, context: Exec = .direct) -> Signal<T> {
		return retry(0, context: context) { (retryCount: inout Int, e: Error) -> DispatchTimeInterval? in
			if e as? SignalError == .closed {
				return nil
			} else if retryCount < count {
				retryCount += 1
				return delayInterval
			} else {
				return nil
			}
		}
	}
	
	/// Implementation of [Reactive X operator "delay"](http://reactivex.io/documentation/operators/delay.html) where delay for each value is determined by running an `offset` function.
	///
	/// - Parameters:
	///   - initialState: a user state value passed into the `offset` function
	///   - closePropagation: determines how errors and closure in `offset` affects the resulting signal
	///   - context: the `Exec` where `offset` will run (default: .Default).
	///   - offset: a function that, when passed the current state value and the latest value from `self`, returns the number of seconds that the value should be delayed (values less or equal to 0 are sent immediately).
	/// - Returns: a mirror of `self` where values are offset according to `offset` – closing occurs when `self` closes or when the last delayed value is sent (whichever occurs last).
	public func delay<U>(initialState: U, closePropagation: SignalClosePropagation = .none, context: Exec = .direct, offset: @escaping (inout U, T) -> DispatchTimeInterval) -> Signal<T> {
		return delay(initialState: initialState, closePropagation: closePropagation, context: context) { (state: inout U, value: T) -> Signal<()> in
			return Signal<()>.timer(interval: offset(&state, value), context: context)
		}
	}
	
	/// Implementation of [Reactive X operator "delay"](http://reactivex.io/documentation/operators/delay.html) where delay for each value is constant.
	///
	/// - Parameters:
	///   - interval: the delay for each value
	///   - context: the `Exec` where timed reconnection will occcur (default: .Default).
	/// - Returns: a mirror of `self` where values are delayed by `seconds` – closing occurs when `self` closes or when the last delayed value is sent (whichever occurs last).
	public func delay(interval: DispatchTimeInterval, context: Exec = .direct) -> Signal<T> {
		return delay(initialState: interval, context: context) { (s: inout DispatchTimeInterval, v: T) -> DispatchTimeInterval in s }
	}
	
	/// Implementation of [Reactive X operator "delay"](http://reactivex.io/documentation/operators/delay.html) where delay for each value is determined by the duration of a signal returned from `offset`.
	///
	/// - Parameters:
	///   - closePropagation: determines how errors and closure in `offset` affects the resulting signal
	///   - context: the `Exec` where `offset` will run (default: .Default).
	///   - offset: a function that, when passed the current state value emits a signal, the first value of which will trigger the end of the delay
	/// - Returns: a mirror of `self` where values are offset according to `offset` – closing occurs when `self` closes or when the last delayed value is sent (whichever occurs last).
	public func delay<U>(closePropagation: SignalClosePropagation = .none, context: Exec = .direct, offset: @escaping (T) -> Signal<U>) -> Signal<T> {
		return delay(initialState: (), closePropagation: closePropagation, context: context) { (state: inout (), value: T) -> Signal<U> in return offset(value) }
	}
	
	/// Implementation of [Reactive X operator "delay"](http://reactivex.io/documentation/operators/delay.html) where delay for each value is determined by the duration of a signal returned from `offset`.
	///
	/// - Parameters:
	///   - initialState: a user state value passed into the `offset` function
	///   - closePropagation: determines how errors and closure in `offset` affects the resulting signal
	///   - context: the `Exec` where `offset` will run (default: .Default).
	///   - offset: a function that, when passed the current state value emits a signal, the first value of which will trigger the end of the delay
	/// - Returns: a mirror of `self` where values are offset according to `offset` – closing occurs when `self` closes or when the last delayed value is sent (whichever occurs last).
	public func delay<U, V>(initialState: V, closePropagation: SignalClosePropagation = .none, context: Exec = .direct, offset: @escaping (inout V, T) -> Signal<U>) -> Signal<T> {
		return valueDurations(initialState: initialState, closePropagation: closePropagation, context: context, duration: offset).transform(initialState: [Int: T]()) { (values: inout [Int: T], r: Result<(Int, T?)>, n: SignalNext<T>) in
			switch r {
			case .success(let index, .some(let t)): values[index] = t
			case .success(let index, .none): _ = values[index].map { n.send(value: $0) }
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "do"](http://reactivex.io/documentation/operators/do.html) for "activation" (not a concept that directly exists in ReactiveX but similar to doOnSubscribe).
	///
	/// - Parameters:
	///   - context: where the handler will be invoked
	///   - handler: invoked when self is activated
	/// - Returns: a signal that emits the same outputs as self
	public func onActivate(context: Exec = .direct, handler: @escaping () -> ()) -> Signal<T> {
		let signal = Signal<T>.generate { input in
			if let i = input {
				do {
					handler()
					try self.join(to: i)
				} catch {
					i.send(error: error)
				}
			}
		}
		return signal
	}
	
	/// Implementation of [Reactive X operator "do"](http://reactivex.io/documentation/operators/do.html) for "deactivation" (not a concept that directly exists in ReactiveX but similar to doOnUnsubscribe).
	///
	/// - Parameters:
	///   - context: where the handler will be invoked
	///   - handler: invoked when self is deactivated
	/// - Returns: a signal that emits the same outputs as self
	public func onDeactivate(context: Exec = .direct, f: @escaping () -> ()) -> Signal<T> {
		let signal = Signal<T>.generate { input in
			if let i = input {
				do {
					try self.join(to: i)
				} catch {
					i.send(error: error)
				}
			} else {
				f()
			}
		}
		return signal
	}
	
	/// Implementation of [Reactive X operator "do"](http://reactivex.io/documentation/operators/do.html) for "result" (equivalent to doOnEach).
	///
	/// - Parameters:
	///   - context: where the handler will be invoked
	///   - handler: invoked for each `Result` in the signal
	/// - Returns: a signal that emits the same outputs as self
	public func onResult(context: Exec = .direct, handler: @escaping (Result<T>) -> ()) -> Signal<T> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<T>) in
			handler(r)
			n.send(result: r)
		}
	}
	
	/// Implementation of [Reactive X operator "do"](http://reactivex.io/documentation/operators/do.html) for "values" (equivalent to doOnNext).
	///
	/// - Parameters:
	///   - context: where the handler will be invoked
	///   - handler: invoked for each value (Result.success) in the signal
	/// - Returns: a signal that emits the same outputs as self
	public func onValue(context: Exec = .direct, handler: @escaping (T) -> ()) -> Signal<T> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<T>) in
			switch r {
			case .success(let v):
				handler(v)
				n.send(value: v)
			case .failure(let e):
				n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "do"](http://reactivex.io/documentation/operators/do.html) for "errors" (equivalent to doOnTerminate).
	///
	/// - Parameters:
	///   - context: where the handler will be invoked
	///   - handler: invoked for each error (Result.failure) in the signal
	/// - Returns: a signal that emits the same outputs as self
	public func onError(context: Exec = .direct, handler: @escaping (Error) -> ()) -> Signal<T> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<T>) in
			switch r {
			case .success(let v):
				n.send(value: v)
			case .failure(let e):
				handler(e)
				n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "materialize"](http://reactivex.io/documentation/operators/materialize-dematerialize.html)
	///
	/// WARNING: in CwlSignal, this operator will emit a `SignalError.closed` into the output signal immediately after emitting the first wrapped error. Within the "first error closes signal" behavior of CwlSignal, this is the only behavior that makes sense (since no further upstream values will be received), however, it does limit the usefulness of `materialize` to constructions where the `materialize` signal immediately outputs into a `SignalMergeSet` (including abstractions built on top, like `switchLatest` or child signals of a `flatMap`) that ignore non-error close conditions from the source signal.
	///
	/// - Returns: a signal where each `Result` emitted from self is further wrapped in a Result.success.
	public func materialize() -> Signal<Result<T>> {
		return transform { r, n in
			n.send(value: r)
			if r.isError {
				n.send(error: SignalError.closed)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "dematerialize"](http://reactivex.io/documentation/operators/materialize-dematerialize.html)
	///
	/// NOTE: ideally, this would not be a static function but a "same type" conditional extension. In a future Swift release this will probably change.
	///
	/// - Parameter signal: a signal whose ValueType is a `Result` wrapped version of an underlying type
	/// - Returns: a signal whose ValueType is the unwrapped value from the input, with unwrapped errors sent as errors.
	public static func dematerialize<T>(_ signal: Signal<Result<T>>) -> Signal<T> {
		return signal.transform { (r: Result<Result<T>>, n: SignalNext<T>) in
			switch r {
			case .success(.success(let v)): n.send(value: v)
			case .success(.failure(let e)): n.send(error: e)
			case .failure(let e): n.send(error: e)
			}
		}
	}
}

extension Signal {
	/// - Note: the [Reactive X operator "ObserveOn"](http://reactivex.io/documentation/operators/observeon.html) doesn't apply to CwlSignal.Signal since any CwlSignal.Signal that runs work can specify their own execution context and control scheduling in that way.
	
	/// - Note: the [Reactive X operator "Serialize"](http://reactivex.io/documentation/operators/serialize.html) doesn't apply to CwlSignal.Signal since all CwlSignal.Signal instances are always serialized and well-behaved under multi-threaded access.
	
	/// - Note: the [Reactive X operator "Subscribe" and "SubscribeOn"](http://reactivex.io/documentation/operators/subscribe.html) are implemented as `subscribe`.
}

extension Signal {
	/// Implementation of [Reactive X operator "TimeInterval"](http://reactivex.io/documentation/operators/timeinterval.html)
	///
	/// - Parameter context: time between emissions will be calculated based on the timestamps from this context
	/// - Returns: a signal where the values are seconds between emissions from self
	public func timeInterval(context: Exec = .direct) -> Signal<Double> {
		let signal = Signal<()>.generate { input in
			if let i = input {
				do {
					i.send(value: ())
					try self.map { v in () }.join(to: i)
				} catch {
					i.send(error: error)
				}
			}
		}.transform(initialState: nil, context: context) { (lastTime: inout DispatchTime?, r: Result<()>, n: SignalNext<Double>) in
			switch r {
			case .success:
				let currentTime = context.timestamp()
				if let l = lastTime {
					n.send(value: currentTime.since(l).toSeconds())
				}
				lastTime = currentTime
			case .failure(let e): n.send(error: e)
			}
		}
		return signal
	}
	
	/// Implementation of [Reactive X operator "Timeout"](http://reactivex.io/documentation/operators/timeout.html)
	///
	/// - Parameters:
	///   - interval: the duration before a SignalError.timeout will be emitted
	///   - resetOnValue: if `true`, each value sent through the signal will reset the timer (making the timeout an "idle" timeout). If `false`, the timeout duration is measured from the start of the signal and is unaffected by whether values are received.
	///   - context: timestamps will be added based on the time in this context
	/// - Returns: a mirror of self unless a timeout occurs, in which case it will closed by a SignalError.timeout
	public func timeout(interval: DispatchTimeInterval, resetOnValue: Bool = true, context: Exec = .direct) -> Signal<T> {
		let (junction, signal) = Signal<()>.timer(interval: interval, context: context).junctionSignal()
		return self.combine(second: signal, context: context) { (cr: EitherResult2<T, ()>, n: SignalNext<T>) in
			switch cr {
			case .result1(let r):
				if resetOnValue {
					junction.rejoin()
				}
				n.send(result: r)
			case .result2: n.send(error: SignalError.timeout)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Timestamp"](http://reactivex.io/documentation/operators/timestamp.html)
	///
	/// - Parameter context: used as the source of time
	/// - Returns: a signal where the values are a two element tuple, first element is self.ValueType, second element is the `DispatchTime` timestamp that this element was emitted from self.
	public func timestamp(context: Exec = .direct) -> Signal<(T, DispatchTime)> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<(T, DispatchTime)>) in
			switch r {
			case .success(let v): n.send(value: (v, context.timestamp()))
			case .failure(let e): n.send(error: e)
			}
		}
	}
}

extension Signal {
	/// - Note: the [Reactive X operator "Using"](http://reactivex.io/documentation/operators/using.html) doesn't apply to CwlSignal.Signal which uses standard Swift reference counted lifetimes. Resources should be captured by closures or `transform(initialState:...)`.
}

extension Signal {
	/// Implementation of [Reactive X operator "All"](http://reactivex.io/documentation/operators/all.html)
	///
	/// - Parameters:
	///   - context: the `test` function will be run in this context
	///   - test: will be invoked for every value
	/// - Returns: a signal that emits true and then closes if every value emitted by self returned true from the `test` function and self closed normally, otherwise emits false and then closes
	public func all(context: Exec = .direct, test: @escaping (T) -> Bool) -> Signal<Bool> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<Bool>) in
			switch r {
			case .success(let v) where !test(v):
				n.send(value: false)
				n.close()
			case .failure(SignalError.closed):
				n.send(value: true)
				n.close()
			case .failure(let e): n.send(error: e)
			default: break;
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Amb"](http://reactivex.io/documentation/operators/amb.html)
	///
	/// - Parameter inputs: a set of inputs
	/// - Returns: connects to all inputs then emits the full set of values from the first of these to emit a value
	public static func amb<S: Sequence>(inputs: S) -> Signal<T> where S.Iterator.Element == Signal<T> {
		let (mergeSet, signal) = Signal<(Int, Result<T>)>.createMergeSet()
		inputs.enumerated().forEach { s in
			_ = try? mergeSet.add(s.element.transform { r, n in
				n.send(value: (s.offset, r))
			}, closePropagation: .errors)
		}
		return signal.transform(initialState: -1) { (first: inout Int, r: Result<(Int, Result<T>)>, n: SignalNext<T>) in
			switch r {
			case .success(let index, let underlying) where first < 0:
				first = index
				n.send(result: underlying)
			case .success(let index, let underlying) where first < 0 || first == index: n.send(result: underlying)
			case .failure(let e): n.send(error: e)
			default: break
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Some"](http://reactivex.io/documentation/operators/some.html)
	///
	/// - Parameters:
	///   - context: the `test` function will be run in this context
	///   - test: will be invoked for every value
	/// - Returns: a signal that emits true and then closes when a value emitted by self returns true from the `test` function, otherwise if no values from self return true, emits false and then closes
	public func some(context: Exec = .direct, test: @escaping (T) -> Bool) -> Signal<Bool> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<Bool>) in
			switch r {
			case .success(let v) where test(v):
				n.send(value: true)
				n.close()
			case .success:
				break
			case .failure(let e):
				n.send(value: false)
				n.send(error: e)
			}
		}
	}
}

extension Signal where T: Equatable {
	/// Implementation of [Reactive X operator "Some"](http://reactivex.io/documentation/operators/some.html)
	///
	/// - Parameter value: every value emitted by self is tested for equality with this value
	/// - Returns: a signal that emits true and then closes when a value emitted by self tests as `==` to `value`, otherwise if no values from self test as equal, emits false and then closes
	public func contains(value: T) -> Signal<Bool> {
		return some { value == $0 }
	}
}

extension Signal {
	/// Implementation of [Reactive X operator "DefaultIfEmpty"](http://reactivex.io/documentation/operators/defaultifempty.html)
	///
	/// - Parameter value: value to emit if self closes without a value
	/// - Returns: a signal that emits the same values as self or `value` if self closes without emitting a value
	public func defaultIfEmpty(value: T) -> Signal<T> {
		return transform(initialState: false) { (started: inout Bool, r: Result<T>, n: SignalNext<T>) in
			switch r {
			case .success(let v):
				started = true
				n.send(value: v)
			case .failure(let e) where !started:
				n.send(value: value)
				n.send(error: e)
			case .failure(let e):
				n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "SwitchIfEmpty"](http://reactivex.io/documentation/operators/switchifempty.html)
	///
	/// - Parameter alternate: content will be used if self closes without emitting a value
	/// - Returns: a signal that emits the same values as self or mirrors `alternate` if self closes without emitting a value
	public func switchIfEmpty(alternate: Signal<T>) -> Signal<T> {
		var fallback: Signal<T>? = alternate
		let (input, signal) = Signal<T>.create { s -> Signal<T> in
			s.map { v in
				fallback = nil
				return v
			}
		}
		do {
			try join(to: input) { (j: SignalJunction<T>, e: Error, i: SignalInput<T>) in
				do {
					if let f = fallback {
						try f.join(to: i)
					} else {
						i.send(error: e)
					}
				} catch {
					i.send(error: error)
				}
			}
		} catch {
			input.send(error: error)
		}
		return signal
	}
}

extension Signal where T: Equatable {
	/// Implementation of [Reactive X operator "SequenceEqual"](http://reactivex.io/documentation/operators/sequenceequal.html)
	///
	/// - Parameter to: another signal whose contents will be compared to this signal
	/// - Returns: a signal that emits `true` if `self` and `to` are equal, `false` otherwise
	public func sequenceEqual(to: Signal<T>) -> Signal<Bool> {
		return combine(initialState: (Array<T>(), Array<T>(), false, false), second: to) { (state: inout (lq: Array<T>, rq: Array<T>, lc: Bool, rc: Bool), r: EitherResult2<T, T>, n: SignalNext<Bool>) in
			// state consists of lq (left queue), rq (right queue), lc (left closed), rc (right closed)
			switch (r, state.lq.first, state.rq.first) {
			case (.result1(.success(let left)), _, .some(let right)):
				if left != right {
					n.send(value: false)
					n.close()
				}
				state.rq.removeFirst()
			case (.result1(.success(let left)), _, _):
				state.lq.append(left)
			case (.result2(.success(let right)), .some(let left), _):
				if left != right {
					n.send(value: false)
					n.close()
				}
				state.lq.removeFirst()
			case (.result2(.success(let right)), _, _):
				state.rq.append(right)
			case (.result1(.failure(let e)), _, _):
				state.lc = true
				if state.rc {
					if state.lq.count == state.rq.count {
						n.send(value: true)
					} else {
						n.send(value: false)
					}
					n.send(error: e)
				}
			case (.result2(.failure(let e)), _, _):
				state.rc = true
				if state.lc {
					if state.lq.count == state.rq.count {
						n.send(value: true)
					} else {
						n.send(value: false)
					}
					n.send(error: e)
				}
			}
		}
	}
}

extension Signal {
	/// Implementation of [Reactive X operator "SkipUntil"](http://reactivex.io/documentation/operators/skipuntil.html)
	///
	/// - Parameter other: until this signal emits a value, all values from self will be dropped
	/// - Returns: a signal that mirrors `self` after `other` emits a value (but won't emit anything prior)
	public func skipUntil<U>(_ other: Signal<U>) -> Signal<T> {
		return combine(initialState: false, second: other) { (started: inout Bool, cr: EitherResult2<T, U>, n: SignalNext<T>) in
			switch cr {
			case .result1(.success(let v)) where started: n.send(value: v)
			case .result1(.success): break
			case .result1(.failure(let e)): n.send(error: e)
			case .result2(.success): started = true
			case .result2(.failure): break
			}
		}
	}
	
	/// Implementation of [Reactive X operator "SkipWhile"](http://reactivex.io/documentation/operators/skipwhile.html)
	///
	/// - Parameters:
	///   - context: execution context where `condition` will be run
	///   - condition: will be run for every value emitted from `self` until `condition` returns `true`
	/// - Returns: a signal that mirrors `self` dropping values until `condition` returns `true` for one of the values
	public func skipWhile(context: Exec = .direct, condition: @escaping (T) -> Bool) -> Signal<T> {
		return transform(initialState: false, context: context) { (started: inout Bool, r: Result<T>, n: SignalNext<T>) in
			switch r {
			case .success(let v) where !started && condition(v):
				break
			case .success(let v):
				started = true
				n.send(value: v)
			case .failure(let e):
				n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "SkipWhile"](http://reactivex.io/documentation/operators/skipwhile.html)
	///
	/// - Parameters:
	///   - initialState: intial value for a state parameter that will be passed to `condition` on each invocation
	///   - context: execution context where `condition` will be run
	///   - condition: will be run for every value emitted from `self` until `condition` returns `true`
	/// - Returns: a signal that mirrors `self` dropping values until `condition` returns `true` for one of the values
	public func skipWhile<U>(initialState initial: U, context: Exec = .direct, condition: @escaping (inout U, T) -> Bool) -> Signal<T> {
		return transform(initialState: (initial, false), context: context) { (started: inout (U, Bool), r: Result<T>, n: SignalNext<T>) in
			switch r {
			case .success(let v) where !started.1 && condition(&started.0, v):
				break
			case .success(let v):
				started.1 = true
				n.send(value: v)
			case .failure(let e):
				n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "TakeUntil"](http://reactivex.io/documentation/operators/takeuntil.html)
	///
	/// - Parameter other: after this signal emits a value, all values from self will be dropped
	/// - Returns: a signal that mirrors `self` until `other` emits a value (but won't emit anything after)
	public func takeUntil<U>(_ other: Signal<U>) -> Signal<T> {
		return combine(initialState: false, second: other) { (started: inout Bool, cr: EitherResult2<T, U>, n: SignalNext<T>) in
			switch cr {
			case .result1(.success(let v)) where !started: n.send(value: v)
			case .result1(.success): break
			case .result1(.failure(let e)): n.send(error: e)
			case .result2(.success): started = true
			case .result2(.failure): break
			}
		}
	}
	
	/// Implementation of [Reactive X operator "TakeWhile"](http://reactivex.io/documentation/operators/takewhile.html)
	///
	/// - Parameters:
	///   - context: execution context where `condition` will be run
	///   - condition: will be run for every value emitted from `self` until `condition` returns `true`
	/// - Returns: a signal that mirrors `self` dropping values after `condition` returns `true` for one of the values
	public func takeWhile(context: Exec = .direct, condition: @escaping (T) -> Bool) -> Signal<T> {
		return transform(context: context) { (r: Result<T>, n: SignalNext<T>) in
			switch r {
			case .success(let v) where condition(v): n.send(value: v)
			case .success: n.close()
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "TakeWhile"](http://reactivex.io/documentation/operators/takewhile.html)
	///
	/// - Parameters:
	///   - initialState: intial value for a state parameter that will be passed to `condition` on each invocation
	///   - context: execution context where `condition` will be run
	///   - condition: will be run for every value emitted from `self` until `condition` returns `true`
	/// - Returns: a signal that mirrors `self` dropping values after `condition` returns `true` for one of the values
	public func takeWhile<U>(initialState initial: U, context: Exec = .direct, condition: @escaping (inout U, T) -> Bool) -> Signal<T> {
		return transform(initialState: initial, context: context) { (i: inout U, r: Result<T>, n: SignalNext<T>) in
			switch r {
			case .success(let v) where condition(&i, v): n.send(value: v)
			case .success: n.close()
			case .failure(let e): n.send(error: e)
			}
		}
	}
	
	/// A helper method used for mathematical operators. Performs a basic `fold` over the values emitted by `self` then passes the final result through another `finalize` function before emitting the result as a value in the returned signal.
	///
	/// - Parameters:
	///   - initial: used to initialize the fold state
	///   - context: all functions will be invoked in this context
	///   - finalize: invoked when `self` closes, with the current fold state value
	///   - fold: invoked for each value emitted by `self` along with the current fold state value
	/// - Returns: a signal which emits the `finalize` result
	public func foldAndFinalize<U, V>(_ initial: V, context: Exec = .direct, finalize: @escaping (V) -> U?, fold: @escaping (V, T) -> V) -> Signal<U> {
		return transform(initialState: initial, context: context) { (state: inout V, r: Result<T>, n: SignalNext<U>) in
			switch r {
			case .success(let v):
				state = fold(state, v)
			case .failure(let e):
				if let v = finalize(state) {
					n.send(value: v)
				}
				n.send(error: e)
			}
		}
	}
}

extension Signal where T: BinaryInteger {
	/// Implementation of [Reactive X operator "Average"](http://reactivex.io/documentation/operators/average.html)
	///
	/// - Returns: a signal that emits a single value... the sum of all values emitted by `self`
	public func average() -> Signal<T> {
		return foldAndFinalize((0, 0), finalize: { (fold: (T, T)) -> T? in fold.0 > 0 ? fold.1 / fold.0 : nil }) { (fold: (T, T), value: T) -> (T, T) in
			return (fold.0 + 1, fold.1 + value)
		}
	}
}

extension Signal {
	/// Implementation of [Reactive X operator "Concat"](http://reactivex.io/documentation/operators/concat.html)
	///
	/// - Parameter other: a second signal
	/// - Returns: a signal that emits all the values from `self` followed by all the values from `other` (including those emitted while `self` was still active)
	public func concat(_ other: Signal<T>) -> Signal<T> {
		return combine(initialState: ([T](), nil, nil), second: other) { (state: inout (secondValues: [T], firstError: Error?, secondError: Error?), cr: EitherResult2<T, T>, n: SignalNext<T>) in
			switch (cr, state.firstError) {
			case (.result1(.success(let v)), _):
				n.send(value: v)
			case (.result1(.failure(let e1)), _):
				for v in state.secondValues {
					n.send(value: v)
				}
				if let e2 = state.secondError {
					n.send(error: e2)
				} else {
					state.firstError = e1
				}
			case (.result2(.success(let v)), .none):
				state.secondValues.append(v)
			case (.result2(.success(let v)), .some):
				n.send(value: v)
			case (.result2(.failure(let e2)), .none):
				state.secondError = e2
			case (.result2(.failure(let e2)), .some):
				n.send(error: e2)
			}
		}
	}
	
	/// Implementation of [Reactive X operator "Count"](http://reactivex.io/documentation/operators/count.html)
	///
	/// - Returns: a signal that emits the number of values emitted by `self`
	public func count() -> Signal<Int> {
		return reduce(0) { (fold: (Int), value: T) -> Int in
			return fold + 1
		}
	}
}

extension Signal where T: Comparable {
	/// Implementation of [Reactive X operator "Min"](http://reactivex.io/documentation/operators/min.html)
	///
	/// - Returns: the smallest value emitted by self
	public func min() -> Signal<T> {
		return foldAndFinalize(nil, finalize: { $0 }) { (fold: T?, value: T) -> T? in
			return fold.map { value < $0 ? value : $0 } ?? value
		}
	}
	
	/// Implementation of [Reactive X operator "Max"](http://reactivex.io/documentation/operators/max.html)
	///
	/// - Returns: the largest value emitted by self
	public func max() -> Signal<T> {
		return foldAndFinalize(nil, finalize: { $0 }) { (fold: T?, value: T) -> T? in
			return fold.map { value > $0 ? value : $0 } ?? value
		}
	}
}

extension Signal {
	/// Implementation of [Reactive X operator "Reduce"](http://reactivex.io/documentation/operators/reduce.html)
	///
	/// See also: `scan` which applies the same logic but emits the `fold` value on *every* invocation.
	///
	/// - Parameters:
	///   - initial: initialize the state value
	///   - context: the `fold` function will be invoked on this context
	///   - fold: invoked for every value emitted from self
	/// - Returns: emits the last emitted `fold` state value
	public func reduce<U>(_ initial: U, context: Exec = .direct, fold: @escaping (U, T) -> U) -> Signal<U> {
		return foldAndFinalize(initial, context: context, finalize: { $0 }) { (state: U, value: T) in
			return fold(state, value)
		}
	}
}

extension Signal where T: Numeric {
	/// Implementation of [Reactive X operator "Sum"](http://reactivex.io/documentation/operators/sum.html)
	///
	/// - Returns: a signal that emits the sum of all values emitted by self
	public func sum() -> Signal<T> {
		return reduce(0) { (fold: T, value: T) -> T in
			return fold + value
		}
	}
}
//
//  CwlSignalCocoa.swift
//  CwlSignal
//
//  Created by Matt Gallagher on 11/2/16.
//  Copyright © 2016 Matt Gallagher ( http://cocoawithlove.com ). All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

/// Instances of `SignalActionTarget` can be used as the "target" of Cocoa "target-action" events and the result will be emitted as a signal.
/// Instance of this class are owned by the output `signal` so if you're holding onto the signal, you can drop references to this class itself.
open class SignalActionTarget: NSObject {
	private var signalInput: SignalInput<Any?>? = nil
	
	// Ownership note: we are owned by the output signal so we only weakly retain it.
	private weak var signalOutput: SignalMulti<Any?>? = nil
	
	/// The `signal` emits the actions received
	public var signal: SignalMulti<Any?> {
		// If there's a current signal output, return it
		if let so = signalOutput {
			return so
		}
		
		// Otherwise, create a new one
		let (i, s) = Signal<Any?>.create { s in
			// Instead of using a `continuous` transform, use a `customActivation` to do the same thing while capturing `self` so that we're owned by the signal.
			s.customActivation { (b: inout Array<Any?>, e: inout Error?, r: Result<Any?>) in
				withExtendedLifetime(self) {}
				switch r {
				case .success(let v):
					b.removeAll(keepingCapacity: true)
					b.append(v)
				case .failure(let err):
					e = err
				}
			}
		}
		self.signalInput = i
		self.signalOutput = s
		return s
	}
	
	/// Receiver function for the target-action events
	///
	/// - Parameter sender: typical target-action "sender" parameter
	@IBAction public func cwlSignalAction(_ sender: Any?) {
		_ = signalInput?.send(value: sender)
	}
	
	/// Convenience accessor for `#selector(SignalActionTarget<T>.cwlSignalAction(_:))`
	public var selector: Selector { return #selector(SignalActionTarget.cwlSignalAction(_:)) }
}

/// Like `SignalActionTarget` but with a second action method connected to the same target. Useful for situations like NSTableView targets which send single-click and double-click to the same target.
open class SignalDoubleActionTarget: SignalActionTarget {
	private var secondInput: SignalInput<Any?>? = nil
	private weak var secondOutput: SignalMulti<Any?>? = nil

	/// The `signal` emits the actions received
	public var secondSignal: SignalMulti<Any?> {
		// If there's a current signal output, return it
		if let so = secondOutput {
			return so
		}
		
		// Otherwise, create a new one
		let (i, s) = Signal<Any?>.create { s in
			// Instead of using a `continuous` transform, use a `customActivation` to do the same thing while capturing `self` so that we're owned by the signal.
			s.customActivation { (b: inout Array<Any?>, e: inout Error?, r: Result<Any?>) in
				withExtendedLifetime(self) {}
				switch r {
				case .success(let v):
					b.removeAll(keepingCapacity: true)
					b.append(v)
				case .failure(let err):
					e = err
				}
			}
		}
		self.secondInput = i
		self.secondOutput = s
		return s
	}

	/// Receiver function for "secondary" target-action events
	///
	/// - Parameter sender: typical target-action "sender" parameter
	@IBAction public func cwlSignalSecondAction(_ sender: Any?) {
		_ = secondInput?.send(value: sender)
	}
	
	/// Convenience accessor for `#selector(SignalDoubleActionTarget<T>.cwlSignalSecondAction(_:))`
	public var secondSelector: Selector { return #selector(SignalDoubleActionTarget.cwlSignalSecondAction(_:)) }
}

/// This enum contains errors that might be emitted by `signalKeyValueObserving`
///
/// - missingChangeDictionary: the observation failed to supply a change dictionary
public enum SignalObservingError: Error {
	case missingChangeDictionary
}

/// Observe a property via key-value-observing and emit the changes as a Signal<Any>
///
/// - Parameters:
///   - source: will have `addObserver(_:forKeyPath:options:context:)` invoked on it
///   - keyPath: passed to `addObserver(_:forKeyPath:options:context:)`
///   - initial: if true, NSKeyValueObservingOptions.initial is included in the options passed to `addObserver(_:forKeyPath:options:context:)`
/// - Returns: a signal which emits the observation results
public func signalKeyValueObserving(_ source: NSObject, keyPath: String, initial: Bool = true) -> Signal<Any> {
	var observer: KeyValueObserver?
	return Signal<Any>.generate { [weak source] (input: SignalInput<Any>?) -> Void in
		guard let i = input, let s = source else {
			observer = nil
			return
		}
		let options = NSKeyValueObservingOptions.new.union(initial ? NSKeyValueObservingOptions.initial : NSKeyValueObservingOptions())
		observer = KeyValueObserver(source: s, keyPath: keyPath, options: options, callback: { (change, reason) -> Void in
			switch (reason, change[NSKeyValueChangeKey.newKey]) {
			case (.sourceDeleted, _): i.close()
			case (_, .some(let v)): i.send(value: v)
			default: i.send(error: SignalObservingError.missingChangeDictionary)
			}
		})
		withExtendedLifetime(observer) {}
	}
}

extension Signal {
	/// Observe a property via key-value-observing and emit the new values that can be downcast to T. This is just a wrapper around `signalKeyValueObserving` that applies `filterMap` to downcast values to T and emit only if the downcast is successful.
	///
	/// - Parameters:
	///   - target: will have `addObserver(_:forKeyPath:options:context:)` invoked on it
	///   - keyPath: passed to `addObserver(_:forKeyPath:options:context:)`
	///   - initial: if true, NSKeyValueObservingOptions.initial is included in the options passed to `addObserver(_:forKeyPath:options:context:)`
	/// - Returns: a signal which emits the observation results
	public static func keyValueObserving(_ target: NSObject, keyPath: String, initial: Bool = true) -> Signal<T> {
		return signalKeyValueObserving(target, keyPath: keyPath, initial: initial).filterMap { $0 as? T }
	}
}

/// Observe a notification on the
///
/// - Parameters:
///   - center: the NotificationCenter where addObserver will be invoked (`NotificationCenter.default` is the default)
///   - name: the Notification.Name to observer (nil is default)
///   - object: the object to observer (nil is default)
/// - Returns: a signal which emits the observation results
public func signalFromNotifications(center: NotificationCenter = NotificationCenter.default, name: Notification.Name? = nil, object: AnyObject? = nil) -> Signal<Notification> {
	var observerObject: NSObjectProtocol?
	return Signal<Notification>.generate { [weak object] input in
		if let i = input, let o = object {
			observerObject = center.addObserver(forName: name, object: o, queue: nil) { n in
				i.send(value: n)
			}
		} else {
			if let o = observerObject {
				NotificationCenter.default.removeObserver(o)
			}
		}
	}
}

extension Signal {
	/// Attaches a SignalEndpoint that applies all values to a target NSObject using key value coding via the supplied keyPath. The property must match the runtime type of the Signal signal values or a precondition failure will be raised.
	///
	/// - Parameters:
	///   - context: the execution context where the setting will occur
	///   - target: the object upon which `setValue(_:forKeyPath:)` will be invoked
	///   - keyPath: passed to `setValue(_:forKeyPath:)`
	/// - Returns: the `SignalEnpoint` created by this action (releasing the endpoint will cease any further setting)
	public func kvcSetter(context: Exec, target: NSObject, keyPath: String) -> SignalEndpoint<T> {
		return subscribeValues(context: context) { [weak target] (value: ValueType) -> Void in
			target?.setValue(value, forKeyPath: keyPath)
		}
	}
}
