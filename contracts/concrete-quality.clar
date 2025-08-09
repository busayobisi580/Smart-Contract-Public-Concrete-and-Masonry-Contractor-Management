;; Ready-Mix Concrete Quality Contract
;; Monitors concrete suppliers for strength and composition standards

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u500))
(define-constant ERR-SUPPLIER-NOT-FOUND (err u501))
(define-constant ERR-BATCH-NOT-FOUND (err u502))
(define-constant ERR-INVALID-STRENGTH (err u503))
(define-constant ERR-INVALID-SLUMP (err u504))
(define-constant ERR-SUPPLIER-EXISTS (err u505))
(define-constant ERR-BATCH-ALREADY-TESTED (err u506))

;; Data Variables
(define-data-var next-supplier-id uint u1)
(define-data-var next-batch-id uint u1)
(define-data-var quality-fee uint u200000) ;; 0.2 STX in microSTX

;; Data Maps
(define-map suppliers
  { supplier-id: uint }
  {
    principal: principal,
    company-name: (string-ascii 100),
    location: (string-ascii 200),
    certification-block: uint,
    expiry-block: uint,
    quality-rating: uint,
    total-batches: uint,
    failed-batches: uint,
    status: (string-ascii 20),
    violations: uint
  }
)

(define-map supplier-by-principal
  { principal: principal }
  { supplier-id: uint }
)

(define-map concrete-batches
  { batch-id: uint }
  {
    supplier-id: uint,
    mix-design: (string-ascii 50),
    production-block: uint,
    strength-target: uint,
    actual-strength: (optional uint),
    slump-target: uint,
    actual-slump: (optional uint),
    air-content: (optional uint),
    temperature: (optional uint),
    test-block: (optional uint),
    test-result: (string-ascii 20),
    quality-score: uint,
    notes: (string-ascii 300)
  }
)

(define-map quality-inspectors
  { inspector: principal }
  { authorized: bool }
)

(define-map mix-standards
  { mix-design: (string-ascii 50) }
  {
    min-strength: uint,
    max-strength: uint,
    target-slump: uint,
    slump-tolerance: uint,
    min-air-content: uint,
    max-air-content: uint
  }
)

;; Initialize contract owner as quality inspector
(map-set quality-inspectors { inspector: CONTRACT-OWNER } { authorized: true })

;; Initialize mix design standards
(map-set mix-standards
  { mix-design: "3000-psi" }
  {
    min-strength: u2700,
    max-strength: u3300,
    target-slump: u4,
    slump-tolerance: u1,
    min-air-content: u4,
    max-air-content: u7
  }
)
(map-set mix-standards
  { mix-design: "4000-psi" }
  {
    min-strength: u3600,
    max-strength: u4400,
    target-slump: u3,
    slump-tolerance: u1,
    min-air-content: u4,
    max-air-content: u7
  }
)

;; Private Functions
(define-private (is-quality-inspector (user principal))
  (default-to false (get authorized (map-get? quality-inspectors { inspector: user })))
)

(define-private (calculate-expiry-block (certification-block uint))
  (+ certification-block u52560) ;; Add approximately 1 year in blocks
)

(define-private (calculate-quality-score
  (strength-target uint)
  (actual-strength uint)
  (slump-target uint)
  (actual-slump uint)
  (air-content uint)
)
  (let (
    (strength-variance (if (>= actual-strength strength-target)
      (/ (* (- actual-strength strength-target) u100) strength-target)
      (/ (* (- strength-target actual-strength) u100) strength-target)
    ))
    (slump-variance (if (>= actual-slump slump-target)
      (- actual-slump slump-target)
      (- slump-target actual-slump)
    ))
    (base-score u100)
  )
    (let (
      (strength-penalty (if (> strength-variance u10) u20 u0))
      (slump-penalty (if (> slump-variance u1) u15 u0))
      (air-penalty (if (or (< air-content u4) (> air-content u7)) u10 u0))
    )
      (- base-score (+ strength-penalty (+ slump-penalty air-penalty)))
    )
  )
)

(define-private (meets-standards (mix-design (string-ascii 50)) (strength uint) (slump uint) (air uint))
  (match (map-get? mix-standards { mix-design: mix-design })
    standards
      (and
        (>= strength (get min-strength standards))
        (<= strength (get max-strength standards))
        (>= slump (- (get target-slump standards) (get slump-tolerance standards)))
        (<= slump (+ (get target-slump standards) (get slump-tolerance standards)))
        (>= air (get min-air-content standards))
        (<= air (get max-air-content standards))
      )
    false
  )
)

;; Public Functions

;; Register concrete supplier
(define-public (register-supplier (company-name (string-ascii 100)) (location (string-ascii 200)))
  (let (
    (supplier-id (var-get next-supplier-id))
    (current-block block-height)
    (expiry-block (calculate-expiry-block current-block))
  )
    ;; Check if supplier already exists
    (asserts! (is-none (map-get? supplier-by-principal { principal: tx-sender })) ERR-SUPPLIER-EXISTS)

    ;; Store supplier data
    (map-set suppliers
      { supplier-id: supplier-id }
      {
        principal: tx-sender,
        company-name: company-name,
        location: location,
        certification-block: current-block,
        expiry-block: expiry-block,
        quality-rating: u100,
        total-batches: u0,
        failed-batches: u0,
        status: "certified",
        violations: u0
      }
    )

    ;; Create principal mapping
    (map-set supplier-by-principal
      { principal: tx-sender }
      { supplier-id: supplier-id }
    )

    ;; Increment supplier ID
    (var-set next-supplier-id (+ supplier-id u1))

    (ok supplier-id)
  )
)

;; Submit concrete batch for testing
(define-public (submit-batch
  (mix-design (string-ascii 50))
  (strength-target uint)
  (slump-target uint)
  (notes (string-ascii 300))
)
  (let (
    (batch-id (var-get next-batch-id))
    (current-block block-height)
    (supplier-ref (unwrap! (map-get? supplier-by-principal { principal: tx-sender }) ERR-SUPPLIER-NOT-FOUND))
    (supplier-id (get supplier-id supplier-ref))
  )
    ;; Validate strength and slump targets
    (asserts! (and (>= strength-target u2000) (<= strength-target u8000)) ERR-INVALID-STRENGTH)
    (asserts! (and (>= slump-target u1) (<= slump-target u8)) ERR-INVALID-SLUMP)

    ;; Store batch data
    (map-set concrete-batches
      { batch-id: batch-id }
      {
        supplier-id: supplier-id,
        mix-design: mix-design,
        production-block: current-block,
        strength-target: strength-target,
        actual-strength: none,
        slump-target: slump-target,
        actual-slump: none,
        air-content: none,
        temperature: none,
        test-block: none,
        test-result: "pending",
        quality-score: u0,
        notes: notes
      }
    )

    ;; Increment batch ID
    (var-set next-batch-id (+ batch-id u1))

    (ok batch-id)
  )
)

;; Test concrete batch (quality inspector only)
(define-public (test-batch
  (batch-id uint)
  (actual-strength uint)
  (actual-slump uint)
  (air-content uint)
  (temperature uint)
)
  (let (
    (batch-data (unwrap! (map-get? concrete-batches { batch-id: batch-id }) ERR-BATCH-NOT-FOUND))
    (current-block block-height)
    (quality-score (calculate-quality-score
      (get strength-target batch-data)
      actual-strength
      (get slump-target batch-data)
      actual-slump
      air-content
    ))
    (test-result (if (meets-standards (get mix-design batch-data) actual-strength actual-slump air-content)
      "pass"
      "fail"
    ))
  )
    ;; Verify inspector authorization
    (asserts! (is-quality-inspector tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get test-result batch-data) "pending") ERR-BATCH-ALREADY-TESTED)

    ;; Update batch test results
    (map-set concrete-batches
      { batch-id: batch-id }
      (merge batch-data {
        actual-strength: (some actual-strength),
        actual-slump: (some actual-slump),
        air-content: (some air-content),
        temperature: (some temperature),
        test-block: (some current-block),
        test-result: test-result,
        quality-score: quality-score
      })
    )

    ;; Update supplier statistics
    (let (
      (supplier-data (unwrap-panic (map-get? suppliers { supplier-id: (get supplier-id batch-data) })))
      (new-total-batches (+ (get total-batches supplier-data) u1))
      (new-failed-batches (if (is-eq test-result "fail")
        (+ (get failed-batches supplier-data) u1)
        (get failed-batches supplier-data)
      ))
    )
      (map-set suppliers
        { supplier-id: (get supplier-id batch-data) }
        (merge supplier-data {
          total-batches: new-total-batches,
          failed-batches: new-failed-batches
        })
      )
    )

    (ok { test-result: test-result, quality-score: quality-score })
  )
)

;; Update supplier quality rating (quality inspector only)
(define-public (update-quality-rating (supplier-id uint) (new-rating uint))
  (let (
    (supplier-data (unwrap! (map-get? suppliers { supplier-id: supplier-id }) ERR-SUPPLIER-NOT-FOUND))
  )
    ;; Verify inspector authorization
    (asserts! (is-quality-inspector tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= new-rating u0) (<= new-rating u100)) ERR-INVALID-STRENGTH)

    ;; Update quality rating
    (map-set suppliers
      { supplier-id: supplier-id }
      (merge supplier-data { quality-rating: new-rating })
    )

    (ok new-rating)
  )
)

;; Suspend supplier (quality inspector only)
(define-public (suspend-supplier (supplier-id uint) (reason (string-ascii 200)))
  (let (
    (supplier-data (unwrap! (map-get? suppliers { supplier-id: supplier-id }) ERR-SUPPLIER-NOT-FOUND))
  )
    ;; Verify inspector authorization
    (asserts! (is-quality-inspector tx-sender) ERR-NOT-AUTHORIZED)

    ;; Update status and increment violations
    (map-set suppliers
      { supplier-id: supplier-id }
      (merge supplier-data {
        status: "suspended",
        violations: (+ (get violations supplier-data) u1)
      })
    )

    (ok true)
  )
)

;; Add quality inspector
(define-public (add-quality-inspector (new-inspector principal))
  (begin
    (asserts! (is-quality-inspector tx-sender) ERR-NOT-AUTHORIZED)
    (map-set quality-inspectors { inspector: new-inspector } { authorized: true })
    (ok true)
  )
)

;; Read-only Functions

;; Get supplier by ID
(define-read-only (get-supplier (supplier-id uint))
  (map-get? suppliers { supplier-id: supplier-id })
)

;; Get supplier by principal
(define-read-only (get-supplier-by-principal (supplier-principal principal))
  (match (map-get? supplier-by-principal { principal: supplier-principal })
    supplier-ref (map-get? suppliers { supplier-id: (get supplier-id supplier-ref) })
    none
  )
)

;; Get batch by ID
(define-read-only (get-batch (batch-id uint))
  (map-get? concrete-batches { batch-id: batch-id })
)

;; Get mix design standards
(define-read-only (get-mix-standards (mix-design (string-ascii 50)))
  (map-get? mix-standards { mix-design: mix-design })
)

;; Check if supplier is certified
(define-read-only (is-supplier-certified (supplier-id uint))
  (match (map-get? suppliers { supplier-id: supplier-id })
    supplier-data
      (and
        (is-eq (get status supplier-data) "certified")
        (> (get expiry-block supplier-data) block-height)
      )
    false
  )
)

;; Calculate supplier failure rate
(define-read-only (get-supplier-failure-rate (supplier-id uint))
  (match (map-get? suppliers { supplier-id: supplier-id })
    supplier-data
      (let (
        (total (get total-batches supplier-data))
        (failed (get failed-batches supplier-data))
      )
        (if (> total u0)
          (/ (* failed u100) total)
          u0
        )
      )
    u0
  )
)

;; Get total suppliers
(define-read-only (get-total-suppliers)
  (- (var-get next-supplier-id) u1)
)

;; Get total batches
(define-read-only (get-total-batches)
  (- (var-get next-batch-id) u1)
)

;; Get quality fee
(define-read-only (get-quality-fee)
  (var-get quality-fee)
)
