import ReactiveCocoa
import Result
import Prelude
import ReactiveExtensions


/**
 Returns signals that can be used to coordinate the process of paginating through values. This function is
 specific to the type of pagination in which a page's results contains a cursor that can be used to request
 the next page of values.

 This function is generic over 4 parameters:

 * `Value`:         The type of value that is being paginated, i.e. a single row, not the array of rows. The
                    value must be equatable.
 * `Envelope`:      The type of response we get from fetching a new page of values.
 * `ErrorEnvelope`: The type of error we might get from fetching a new page of values.
 * `Cursor`:        The type of value that can be extracted from `Envelope` to request the next page of
                    values.
 * `RequestParams`: The type that allows us to make a request for values without a cursor.

 - parameter requestFirstPageWith: A signal that emits request params when a first page request should be
                                   made.
 - parameter requestNextPageWhen:  A signal that emits whenever next page of values should be fetched.
 - parameter clearOnNewRequest:    A boolean that determines if results should be cleared when a new request
                                   is made, i.e. an empty array will immediately be emitted.
 - parameter valuesFromEnvelope:   A function to get an array of values from the results envelope.
 - parameter cursorFromEnvelope:   A function to get the cursor for the next page from a results envelope.
 - parameter requestFromParams:    A function to get a request for values from a params value.
 - parameter requestFromCursor:    A function to get a request for values from a cursor value.
 - parameter concater:             An optional function that concats a page of values to the current array of
                                   values. By default this simply concatenates the arrays, but you might want
                                   to do something more specific, such as concatenating only distinct values.

 - returns: A tuple of signals, (paginatedValues, isLoading). The `paginatedValues` signal will emit a full
            set of values when a new page has loaded. The `isLoading` signal will emit `true` while a page of
            values is loading, and then `false` when it has terminated (either by completion or error).
 */
public func paginate <Cursor, Value: Equatable, Envelope, ErrorEnvelope, RequestParams> (
  requestFirstPageWith requestFirstPage: Signal<RequestParams, NoError>,
  requestNextPageWhen  requestNextPage: Signal<(), NoError>,
                       clearOnNewRequest: Bool,
                       valuesFromEnvelope: (Envelope -> [Value]),
                       cursorFromEnvelope: (Envelope -> Cursor),
                       requestFromParams: (RequestParams -> SignalProducer<Envelope, ErrorEnvelope>),
                       requestFromCursor: (Cursor -> SignalProducer<Envelope, ErrorEnvelope>),
                       concater: (([Value], [Value]) -> [Value]) = (+))
  -> (paginatedValues: Signal<[Value], NoError>, isLoading: Signal<Bool, NoError>) {

    let cursor = MutableProperty<Cursor?>(nil)
    let isLoading = MutableProperty<Bool>(false)

    // Emits the last cursor when nextPage emits
    let cursorOnNextPage = cursor.producer.ignoreNil().sampleOn(requestNextPage)

    let paginatedValues = requestFirstPage
      .switchMap { requestParams in

        cursorOnNextPage.map(Either.right)
          .beginsWith(value: Either.left(requestParams))
          .switchMap { paramsOrCursor in

            paramsOrCursor.ifLeft(requestFromParams, ifRight: requestFromCursor)
              .delay(AppEnvironment.current.apiDelayInterval, onScheduler: AppEnvironment.current.scheduler)
              .on(
                started: { [weak isLoading] _ in
                  isLoading?.value = true
                },
                terminated: { [weak isLoading] _ in
                  isLoading?.value = false
                },
                next: { [weak cursor] env in
                  cursor?.value = cursorFromEnvelope(env)
              })
              .map(valuesFromEnvelope)
              .demoteErrors()
          }
          .takeUntil { !$0.isEmpty }
          .mergeWith(clearOnNewRequest ? .init(value: []) : .empty)
          .scan([], concater)
      }
      .skip(clearOnNewRequest ? 1 : 0)
      .skipRepeats(==)

    return (paginatedValues, isLoading.signal)
}
