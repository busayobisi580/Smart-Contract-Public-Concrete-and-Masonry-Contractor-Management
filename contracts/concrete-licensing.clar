;; Concrete Contractor Licensing Contract
;; Manages licensing for concrete pouring and finishing companies

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CONTRACTOR-EXISTS (err u101))
(define-constant ERR-CONTRACTOR-NOT-FOUND (err u102))
(define-constant ERR-INVALID-LICENSE-TYPE (err u103))
(define-constant ERR-LICENSE-EXPIRED (err u104))
(define-constant ERR-INSUFFICIENT-EXPERIENCE (err u105))
(define-constant ERR-INVALID-RATING (err u106))

;; Data Variables
(define-data-var next-contractor-id uint u1)
(define-data-var license-fee uint u1000000) ;; 1 STX in microSTX

;; Data Maps
(define-map contractors
  { contractor-id: uint }
  {
    principal: principal,
    company-name: (string-ascii 100),
    license-type: (string-ascii 50),
    issue-block: uint,
    expiry-block: uint,
    experience-years: uint,
    rating: uint,
    status: (string-ascii 20),
    violations: uint
  }
)

(define-map contractor-by-principal
  { principal: principal }
  { contractor-id: uint }
)

(define-map authorized-admins
  { admin: principal }
  { authorized: bool }
)

;; Initialize contract owner as admin
(map-set authorized-admins { admin: CONTRACT-OWNER } { authorized: true })

;; Private Functions
(define-private (is-admin (user principal))
  (default-to false (get authorized (map-get? authorized-admins { admin: user })))
)

(define-private (is-valid-license-type (license-type (string-ascii 50)))
  (or
    (is-eq license-type "residential")
    (is-eq license-type "commercial")
    (is-eq license-type "industrial")
    (is-eq license-type "specialty")
  )
)

(define-private (calculate-expiry-block (issue-block uint))
  (+ issue-block u52560) ;; Add approximately 1 year in blocks (assuming 10 min blocks)
)

;; Public Functions

;; Register a new concrete contractor
(define-public (register-contractor
  (company-name (string-ascii 100))
  (license-type (string-ascii 50))
  (experience-years uint)
)
  (let (
    (contractor-id (var-get next-contractor-id))
    (current-block block-height)
    (expiry-block (calculate-expiry-block current-block))
  )
    ;; Validate inputs
    (asserts! (is-valid-license-type license-type) ERR-INVALID-LICENSE-TYPE)
    (asserts! (>= experience-years u2) ERR-INSUFFICIENT-EXPERIENCE)
    (asserts! (is-none (map-get? contractor-by-principal { principal: tx-sender })) ERR-CONTRACTOR-EXISTS)

    ;; Store contractor data
    (map-set contractors
      { contractor-id: contractor-id }
      {
        principal: tx-sender,
        company-name: company-name,
        license-type: license-type,
        issue-block: current-block,
        expiry-block: expiry-block,
        experience-years: experience-years,
        rating: u5,
        status: "active",
        violations: u0
      }
    )

    ;; Create principal mapping
    (map-set contractor-by-principal
      { principal: tx-sender }
      { contractor-id: contractor-id }
    )

    ;; Increment contractor ID
    (var-set next-contractor-id (+ contractor-id u1))

    (ok contractor-id)
  )
)

;; Renew contractor license
(define-public (renew-license (contractor-id uint))
  (let (
    (contractor-data (unwrap! (map-get? contractors { contractor-id: contractor-id }) ERR-CONTRACTOR-NOT-FOUND))
    (current-block block-height)
    (new-expiry (calculate-expiry-block current-block))
  )
    ;; Verify contractor owns this license
    (asserts! (is-eq tx-sender (get principal contractor-data)) ERR-NOT-AUTHORIZED)

    ;; Update expiry block
    (map-set contractors
      { contractor-id: contractor-id }
      (merge contractor-data {
        expiry-block: new-expiry,
        status: "active"
      })
    )

    (ok new-expiry)
  )
)

;; Update contractor rating (admin only)
(define-public (update-rating (contractor-id uint) (new-rating uint))
  (let (
    (contractor-data (unwrap! (map-get? contractors { contractor-id: contractor-id }) ERR-CONTRACTOR-NOT-FOUND))
  )
    ;; Verify admin authorization
    (asserts! (is-admin tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= new-rating u1) (<= new-rating u10)) ERR-INVALID-RATING)

    ;; Update rating
    (map-set contractors
      { contractor-id: contractor-id }
      (merge contractor-data { rating: new-rating })
    )

    (ok new-rating)
  )
)

;; Suspend contractor license (admin only)
(define-public (suspend-license (contractor-id uint) (reason (string-ascii 100)))
  (let (
    (contractor-data (unwrap! (map-get? contractors { contractor-id: contractor-id }) ERR-CONTRACTOR-NOT-FOUND))
  )
    ;; Verify admin authorization
    (asserts! (is-admin tx-sender) ERR-NOT-AUTHORIZED)

    ;; Update status and increment violations
    (map-set contractors
      { contractor-id: contractor-id }
      (merge contractor-data {
        status: "suspended",
        violations: (+ (get violations contractor-data) u1)
      })
    )

    (ok true)
  )
)

;; Add authorized admin
(define-public (add-admin (new-admin principal))
  (begin
    (asserts! (is-admin tx-sender) ERR-NOT-AUTHORIZED)
    (map-set authorized-admins { admin: new-admin } { authorized: true })
    (ok true)
  )
)

;; Read-only Functions

;; Get contractor by ID
(define-read-only (get-contractor (contractor-id uint))
  (map-get? contractors { contractor-id: contractor-id })
)

;; Get contractor by principal
(define-read-only (get-contractor-by-principal (contractor-principal principal))
  (match (map-get? contractor-by-principal { principal: contractor-principal })
    contractor-ref (map-get? contractors { contractor-id: (get contractor-id contractor-ref) })
    none
  )
)

;; Check if license is valid
(define-read-only (is-license-valid (contractor-id uint))
  (match (map-get? contractors { contractor-id: contractor-id })
    contractor-data
      (and
        (is-eq (get status contractor-data) "active")
        (> (get expiry-block contractor-data) block-height)
      )
    false
  )
)

;; Get total contractors
(define-read-only (get-total-contractors)
  (- (var-get next-contractor-id) u1)
)

;; Get license fee
(define-read-only (get-license-fee)
  (var-get license-fee)
)
