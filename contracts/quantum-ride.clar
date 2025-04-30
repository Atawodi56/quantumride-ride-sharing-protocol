;; quantum-ride.clar
;; QuantumRide - Decentralized Ride Sharing Protocol
;;
;; This contract manages the entire lifecycle of ride sharing on the QuantumRide platform:
;; - Riders can create and manage ride requests
;; - Drivers can accept rides and update their availability
;; - Funds are held in escrow during rides
;; - Automatic payment settlement upon ride completion
;; - Reputation tracking for both riders and drivers
;; - Simple dispute resolution mechanism

;; ===============
;; Error Constants
;; ===============

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-RIDE-ALREADY-EXISTS (err u102))
(define-constant ERR-RIDE-ALREADY-ACCEPTED (err u103))
(define-constant ERR-RIDE-NOT-ACCEPTED (err u104))
(define-constant ERR-RIDE-ALREADY-COMPLETED (err u105))
(define-constant ERR-RIDE-ALREADY-CANCELED (err u106))
(define-constant ERR-INSUFFICIENT-FUNDS (err u107))
(define-constant ERR-INVALID-FARE (err u108))
(define-constant ERR-INVALID-LOCATION (err u109))
(define-constant ERR-INVALID-STATE (err u110))
(define-constant ERR-DRIVER-NOT-ACTIVE (err u111))
(define-constant ERR-NOT-IN-DISPUTE (err u112))
(define-constant ERR-ALREADY-RATED (err u113))

;; ==================
;; Contract Constants
;; ==================

;; Protocol fee percentage (1% = 10 basis points)
(define-constant PROTOCOL-FEE-BPS u10)
(define-constant BPS-DENOMINATOR u1000)

;; Contract owner who receives protocol fees
(define-constant CONTRACT-OWNER tx-sender)

;; Ride status values
(define-constant STATUS-REQUESTED u1)
(define-constant STATUS-ACCEPTED u2)
(define-constant STATUS-COMPLETED u3)
(define-constant STATUS-CANCELED u4)
(define-constant STATUS-DISPUTED u5)

;; ===============
;; Data Structures
;; ===============

;; Ride request details
(define-map rides
  { ride-id: uint }
  {
    rider: principal,
    driver: (optional principal),
    pickup-location: (string-utf8 100),
    dropoff-location: (string-utf8 100),
    fare-amount: uint,
    status: uint,
    created-at: uint,
    accepted-at: (optional uint),
    completed-at: (optional uint)
  }
)

;; Active ride requests (used for browsing)
(define-map active-ride-requests
  { ride-id: uint }
  { ride-id: uint }
)

;; Driver information and status
(define-map drivers
  { driver: principal }
  {
    active: bool,
    current-location: (optional (string-utf8 100)),
    current-ride-id: (optional uint),
    total-rides: uint,
    reputation-score: uint,
    last-location-update: (optional uint)
  }
)

;; Rider information
(define-map riders
  { rider: principal }
  {
    total-rides: uint,
    reputation-score: uint,
    current-ride-id: (optional uint)
  }
)

;; Reputation ratings for completed rides
(define-map ride-ratings
  { ride-id: uint }
  {
    rider-rating: (optional uint), ;; 1-5 stars from driver
    driver-rating: (optional uint)  ;; 1-5 stars from rider
  }
)

;; Ride counter for generating unique IDs
(define-data-var ride-counter uint u0)

;; =====================
;; Private Functions
;; =====================

;; Generate a new ride ID
(define-private (generate-ride-id)
  (let
    ((new-id (+ (var-get ride-counter) u1)))
    (var-set ride-counter new-id)
    new-id
  )
)

;; Calculate the protocol fee for a given fare
(define-private (calculate-protocol-fee (fare uint))
  (/ (* fare PROTOCOL-FEE-BPS) BPS-DENOMINATOR)
)

;; Update driver reputation score based on a new rating
(define-private (update-driver-reputation (driver principal) (new-rating uint))
  (match (map-get? drivers {driver: driver})
    driver-data
    (let
      (
        (current-score (get reputation-score driver-data))
        (ride-count (get total-rides driver-data))
        (new-score (if (is-eq ride-count u0)
                      new-rating
                      (/ (+ (* current-score ride-count) new-rating) (+ ride-count u1))))
      )
      (map-set drivers
        {driver: driver}
        (merge driver-data {reputation-score: new-score})
      )
      (ok true)
    )
    (err ERR-NOT-FOUND)
  )
)

;; Update rider reputation score based on a new rating
(define-private (update-rider-reputation (rider principal) (new-rating uint))
  (match (map-get? riders {rider: rider})
    rider-data
    (let
      (
        (current-score (get reputation-score rider-data))
        (ride-count (get total-rides rider-data))
        (new-score (if (is-eq ride-count u0)
                      new-rating
                      (/ (+ (* current-score ride-count) new-rating) (+ ride-count u1))))
      )
      (map-set riders
        {rider: rider}
        (merge rider-data {reputation-score: new-score})
      )
      (ok true)
    )
    (err ERR-NOT-FOUND)
  )
)

;; Check if the tx-sender is the rider for a given ride
(define-private (is-rider (ride-id uint))
  (match (map-get? rides {ride-id: ride-id})
    ride (is-eq (get rider ride) tx-sender)
    false
  )
)

;; Check if the tx-sender is the driver for a given ride
(define-private (is-driver (ride-id uint))
  (match (map-get? rides {ride-id: ride-id})
    ride
    (match (get driver ride)
      driver (is-eq driver tx-sender)
      false
    )
    false
  )
)

;; ========================
;; Read-only Functions
;; ========================

;; Get ride details by ID
(define-read-only (get-ride (ride-id uint))
  (map-get? rides {ride-id: ride-id})
)

;; Get driver details
(define-read-only (get-driver-info (driver principal))
  (map-get? drivers {driver: driver})
)

;; Get rider details
(define-read-only (get-rider-info (rider principal))
  (map-get? riders {rider: rider})
)

;; Get ratings for a ride
(define-read-only (get-ride-ratings (ride-id uint))
  (map-get? ride-ratings {ride-id: ride-id})
)

;; Get all active ride requests (limited to 50 for practical reasons)
(define-read-only (get-active-ride-requests)
  (ok (map-get? active-ride-requests))
)

;; Calculate the payment amount after fees
(define-read-only (calculate-payment-amount (fare uint))
  (- fare (calculate-protocol-fee fare))
)

;; =====================
;; Public Functions
;; =====================

;; Initialize or update rider information
(define-public (register-rider)
  (let
    ((rider-exists (is-some (map-get? riders {rider: tx-sender}))))
    (if rider-exists
      (ok true) ;; Rider already registered
      (begin
        (map-set riders
          {rider: tx-sender}
          {
            total-rides: u0,
            reputation-score: u500, ;; Starting score of 5.00 (multiply by 100 for no decimals)
            current-ride-id: none
          }
        )
        (ok true)
      )
    )
  )
)

;; Initialize or update driver information
(define-public (register-driver (location (string-utf8 100)))
  (let
    ((driver-exists (is-some (map-get? drivers {driver: tx-sender}))))
    (if driver-exists
      (begin
        (map-set drivers
          {driver: tx-sender}
          (merge (unwrap-panic (map-get? drivers {driver: tx-sender}))
            {
              active: true,
              current-location: (some location),
              last-location-update: (some block-height)
            }
          )
        )
        (ok true)
      )
      (begin
        (map-set drivers
          {driver: tx-sender}
          {
            active: true,
            current-location: (some location),
            current-ride-id: none,
            total-rides: u0,
            reputation-score: u500, ;; Starting score of 5.00
            last-location-update: (some block-height)
          }
        )
        (ok true)
      )
    )
  )
)

;; Update driver status and location
(define-public (update-driver-status (active bool) (location (optional (string-utf8 100))))
  (match (map-get? drivers {driver: tx-sender})
    driver-data
    (begin
      (map-set drivers
        {driver: tx-sender}
        (merge driver-data 
          {
            active: active,
            current-location: location,
            last-location-update: (some block-height)
          }
        )
      )
      (ok true)
    )
    (err ERR-NOT-FOUND)
  )
)

;; Create a new ride request
(define-public (request-ride 
    (pickup-location (string-utf8 100))
    (dropoff-location (string-utf8 100))
    (fare-amount uint))
  (let
    (
      (ride-id (generate-ride-id))
      (rider-info (map-get? riders {rider: tx-sender}))
    )
    ;; Check rider is registered
    (asserts! (is-some rider-info) (err ERR-NOT-FOUND))
    
    ;; Check fare amount is reasonable
    (asserts! (> fare-amount u0) (err ERR-INVALID-FARE))
    
    ;; Check rider has no active ride
    (asserts! (is-none (get current-ride-id (unwrap-panic rider-info))) (err ERR-RIDE-ALREADY-EXISTS))
    
    ;; Check STX balance
    (asserts! (>= (stx-get-balance tx-sender) fare-amount) (err ERR-INSUFFICIENT-FUNDS))
    
    ;; Create the ride
    (map-set rides
      {ride-id: ride-id}
      {
        rider: tx-sender,
        driver: none,
        pickup-location: pickup-location,
        dropoff-location: dropoff-location,
        fare-amount: fare-amount,
        status: STATUS-REQUESTED,
        created-at: block-height,
        accepted-at: none,
        completed-at: none
      }
    )
    
    ;; Add to active ride requests
    (map-set active-ride-requests {ride-id: ride-id} {ride-id: ride-id})
    
    ;; Update rider's current ride
    (map-set riders
      {rider: tx-sender}
      (merge (unwrap-panic rider-info) {current-ride-id: (some ride-id)})
    )
    
    (ok ride-id)
  )
)

;; Cancel a ride request (only by rider and only if not accepted)
(define-public (cancel-ride (ride-id uint))
  (match (map-get? rides {ride-id: ride-id})
    ride
    (begin
      ;; Check the sender is the rider
      (asserts! (is-eq (get rider ride) tx-sender) (err ERR-NOT-AUTHORIZED))
      
      ;; Check ride status is requested
      (asserts! (is-eq (get status ride) STATUS-REQUESTED) (err ERR-INVALID-STATE))
      
      ;; Update ride status
      (map-set rides
        {ride-id: ride-id}
        (merge ride {status: STATUS-CANCELED})
      )
      
      ;; Remove from active ride requests
      (map-delete active-ride-requests {ride-id: ride-id})
      
      ;; Clear rider's current ride
      (match (map-get? riders {rider: tx-sender})
        rider-data
        (map-set riders
          {rider: tx-sender}
          (merge rider-data {current-ride-id: none})
        )
        true
      )
      
      (ok true)
    )
    (err ERR-NOT-FOUND)
  )
)

;; Accept a ride request
(define-public (accept-ride (ride-id uint))
  (match (map-get? rides {ride-id: ride-id})
    ride
    (let
      (
        (driver-info (map-get? drivers {driver: tx-sender}))
      )
      ;; Check driver is registered and active
      (asserts! (is-some driver-info) (err ERR-NOT-FOUND))
      (asserts! (get active (unwrap-panic driver-info)) (err ERR-DRIVER-NOT-ACTIVE))
      
      ;; Check driver has no active ride
      (asserts! (is-none (get current-ride-id (unwrap-panic driver-info))) (err ERR-INVALID-STATE))
      
      ;; Check ride status is requested
      (asserts! (is-eq (get status ride) STATUS-REQUESTED) (err ERR-INVALID-STATE))
      
      ;; Update ride status with driver
      (map-set rides
        {ride-id: ride-id}
        (merge ride 
          {
            driver: (some tx-sender),
            status: STATUS-ACCEPTED,
            accepted-at: (some block-height)
          }
        )
      )
      
      ;; Update driver's current ride
      (map-set drivers
        {driver: tx-sender}
        (merge (unwrap-panic driver-info) 
          {current-ride-id: (some ride-id)}
        )
      )
      
      ;; Escrow the funds from rider
      (match (stx-transfer? (get fare-amount ride) (get rider ride) (as-contract tx-sender))
        success (ok true)
        error (err ERR-INSUFFICIENT-FUNDS)
      )
    )
    (err ERR-NOT-FOUND)
  )
)

;; Complete a ride (only by driver)
(define-public (complete-ride (ride-id uint))
  (match (map-get? rides {ride-id: ride-id})
    ride
    (begin
      ;; Check the sender is the driver
      (asserts! (is-driver ride-id) (err ERR-NOT-AUTHORIZED))
      
      ;; Check ride status is accepted
      (asserts! (is-eq (get status ride) STATUS-ACCEPTED) (err ERR-INVALID-STATE))
      
      ;; Update ride status
      (map-set rides
        {ride-id: ride-id}
        (merge ride 
          {
            status: STATUS-COMPLETED,
            completed-at: (some block-height)
          }
        )
      )
      
      (ok true)
    )
    (err ERR-NOT-FOUND)
  )
)

;; Confirm ride completion and release payment (only by rider)
(define-public (confirm-ride-completion (ride-id uint))
  (match (map-get? rides {ride-id: ride-id})
    ride
    (let
      (
        (fare (get fare-amount ride))
        (protocol-fee (calculate-protocol-fee fare))
        (driver-payment (- fare protocol-fee))
        (driver-principal (unwrap! (get driver ride) (err ERR-NOT-FOUND)))
        (rider-principal (get rider ride))
      )
      ;; Check the sender is the rider
      (asserts! (is-eq rider-principal tx-sender) (err ERR-NOT-AUTHORIZED))
      
      ;; Check ride status is completed
      (asserts! (is-eq (get status ride) STATUS-COMPLETED) (err ERR-INVALID-STATE))
      
      ;; Process payment from contract to driver
      (try! (as-contract (stx-transfer? driver-payment driver-principal driver-principal)))
      
      ;; Send protocol fee to contract owner
      (try! (as-contract (stx-transfer? protocol-fee rider-principal CONTRACT-OWNER)))
      
      ;; Update driver stats
      (match (map-get? drivers {driver: driver-principal})
        driver-data
        (map-set drivers
          {driver: driver-principal}
          (merge driver-data 
            {
              current-ride-id: none,
              total-rides: (+ (get total-rides driver-data) u1)
            }
          )
        )
        true
      )
      
      ;; Update rider stats
      (match (map-get? riders {rider: rider-principal})
        rider-data
        (map-set riders
          {rider: rider-principal}
          (merge rider-data 
            {
              current-ride-id: none,
              total-rides: (+ (get total-rides rider-data) u1)
            }
          )
        )
        true
      )
      
      ;; Initialize ratings map for this ride
      (map-set ride-ratings
        {ride-id: ride-id}
        {
          rider-rating: none,
          driver-rating: none
        }
      )
      
      ;; Remove from active ride requests (if still there)
      (map-delete active-ride-requests {ride-id: ride-id})
      
      (ok true)
    )
    (err ERR-NOT-FOUND)
  )
)

;; Rate a driver (only by rider after completion)
(define-public (rate-driver (ride-id uint) (rating uint))
  (match (map-get? rides {ride-id: ride-id})
    ride
    (begin
      ;; Check the sender is the rider
      (asserts! (is-eq (get rider ride) tx-sender) (err ERR-NOT-AUTHORIZED))
      
      ;; Check ride is completed
      (asserts! (is-eq (get status ride) STATUS-COMPLETED) (err ERR-INVALID-STATE))
      
      ;; Check rating is between 1-5
      (asserts! (and (>= rating u1) (<= rating u5)) (err u114))
      
      ;; Check not already rated
      (match (map-get? ride-ratings {ride-id: ride-id})
        ratings
        (asserts! (is-none (get driver-rating ratings)) (err ERR-ALREADY-RATED))
        (err ERR-NOT-FOUND)
      )
      
      ;; Update rating
      (match (get driver ride)
        driver-principal
        (begin
          ;; Update ride ratings
          (map-set ride-ratings
            {ride-id: ride-id}
            (merge (unwrap-panic (map-get? ride-ratings {ride-id: ride-id}))
              {driver-rating: (some rating)}
            )
          )
          
          ;; Update driver reputation
          (try! (update-driver-reputation driver-principal rating))
          
          (ok true)
        )
        (err ERR-NOT-FOUND)
      )
    )
    (err ERR-NOT-FOUND)
  )
)

;; Rate a rider (only by driver after completion)
(define-public (rate-rider (ride-id uint) (rating uint))
  (match (map-get? rides {ride-id: ride-id})
    ride
    (begin
      ;; Check the sender is the driver
      (asserts! (is-driver ride-id) (err ERR-NOT-AUTHORIZED))
      
      ;; Check ride is completed
      (asserts! (is-eq (get status ride) STATUS-COMPLETED) (err ERR-INVALID-STATE))
      
      ;; Check rating is between 1-5
      (asserts! (and (>= rating u1) (<= rating u5)) (err u114))
      
      ;; Check not already rated
      (match (map-get? ride-ratings {ride-id: ride-id})
        ratings
        (asserts! (is-none (get rider-rating ratings)) (err ERR-ALREADY-RATED))
        (err ERR-NOT-FOUND)
      )
      
      ;; Update rating
      (let
        ((rider-principal (get rider ride)))
        ;; Update ride ratings
        (map-set ride-ratings
          {ride-id: ride-id}
          (merge (unwrap-panic (map-get? ride-ratings {ride-id: ride-id}))
            {rider-rating: (some rating)}
          )
        )
        
        ;; Update rider reputation
        (try! (update-rider-reputation rider-principal rating))
        
        (ok true)
      )
    )
    (err ERR-NOT-FOUND)
  )
)

;; Initiate a dispute (from either rider or driver)
(define-public (initiate-dispute (ride-id uint))
  (match (map-get? rides {ride-id: ride-id})
    ride
    (begin
      ;; Check sender is either rider or driver
      (asserts! (or (is-rider ride-id) (is-driver ride-id)) (err ERR-NOT-AUTHORIZED))
      
      ;; Check ride status is accepted or completed
      (asserts! (or 
                 (is-eq (get status ride) STATUS-ACCEPTED)
                 (is-eq (get status ride) STATUS-COMPLETED))
               (err ERR-INVALID-STATE))
      
      ;; Update ride status
      (map-set rides
        {ride-id: ride-id}
        (merge ride {status: STATUS-DISPUTED})
      )
      
      (ok true)
    )
    (err ERR-NOT-FOUND)
  )
)

;; Resolve a dispute (only contract owner for simplicity)
;; In a full implementation, this would use a more sophisticated governance mechanism
(define-public (resolve-dispute (ride-id uint) (refund-percentage uint))
  (match (map-get? rides {ride-id: ride-id})
    ride
    (let
      (
        (fare (get fare-amount ride))
        (rider-refund (/ (* fare refund-percentage) u100))
        (driver-payment (- fare rider-refund))
        (protocol-fee (calculate-protocol-fee driver-payment))
        (final-driver-payment (- driver-payment protocol-fee))
        (driver-principal (unwrap! (get driver ride) (err ERR-NOT-FOUND)))
        (rider-principal (get rider ride))
      )
      ;; Check the sender is the contract owner
      (asserts! (is-eq tx-sender CONTRACT-OWNER) (err ERR-NOT-AUTHORIZED))
      
      ;; Check ride is disputed
      (asserts! (is-eq (get status ride) STATUS-DISPUTED) (err ERR-NOT-IN-DISPUTE))
      
      ;; Check refund percentage is valid (0-100)
      (asserts! (and (>= refund-percentage u0) (<= refund-percentage u100)) (err u115))
      
      ;; Process refund to rider if applicable
      (if (> rider-refund u0)
        (try! (as-contract (stx-transfer? rider-refund rider-principal rider-principal)))
        true
      )
      
      ;; Process payment to driver if applicable
      (if (> final-driver-payment u0)
        (try! (as-contract (stx-transfer? final-driver-payment driver-principal driver-principal)))
        true
      )
      
      ;; Send protocol fee to contract owner
      (try! (as-contract (stx-transfer? protocol-fee rider-principal CONTRACT-OWNER)))
      
      ;; Update ride status
      (map-set rides
        {ride-id: ride-id}
        (merge ride 
          {
            status: STATUS-COMPLETED,
            completed-at: (some block-height)
          }
        )
      )
      
      ;; Update driver stats
      (match (map-get? drivers {driver: driver-principal})
        driver-data
        (map-set drivers
          {driver: driver-principal}
          (merge driver-data 
            {
              current-ride-id: none,
              total-rides: (+ (get total-rides driver-data) u1)
            }
          )
        )
        true
      )
      
      ;; Update rider stats
      (match (map-get? riders {rider: rider-principal})
        rider-data
        (map-set riders
          {rider: rider-principal}
          (merge rider-data 
            {
              current-ride-id: none,
              total-rides: (+ (get total-rides rider-data) u1)
            }
          )
        )
        true
      )
      
      ;; Remove from active ride requests (if still there)
      (map-delete active-ride-requests {ride-id: ride-id})
      
      (ok true)
    )
    (err ERR-NOT-FOUND)
  )
)