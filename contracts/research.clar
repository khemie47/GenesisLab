;; GenesisLab Smart Contract
;; A decentralized platform for funding and verifying scientific research
;; This contract allows:
;; 1. Scientists to submit research proposals
;; 2. Community members to fund proposals with STX
;; 3. Peer review and verification of completed research
;; 4. Distribution of research findings as NFTs

(define-data-var admin principal tx-sender)
(define-map proposals
  { proposal-id: uint }
  {
    scientist: principal,
    title: (string-utf8 100),
    abstract: (string-utf8 500),
    funding-goal: uint,
    current-funding: uint,
    status: (string-utf8 20),  ;; "proposed", "funded", "in-progress", "complete", "verified"
    ipfs-hash: (optional (string-utf8 46)),
    reviewers: (list 5 principal)
  }
)

(define-map funders
  { proposal-id: uint, funder: principal }
  { amount: uint }
)

(define-map peer-reviews
  { proposal-id: uint, reviewer: principal }
  {
    score: uint,  ;; 1-10
    comments: (string-utf8 500),
    verified: bool
  }
)

(define-non-fungible-token research-findings uint)

(define-data-var proposal-counter uint u0)

;; ====================
;; Admin functions
;; ====================

(define-public (set-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err u403))
    (ok (var-set admin new-admin))
  )
)

;; ====================
;; Scientist functions
;; ====================

(define-public (submit-proposal (title (string-utf8 100)) (abstract (string-utf8 500)) (funding-goal uint))
  (let
    ((proposal-id (var-get proposal-counter)))
    (asserts! (> funding-goal u0) (err u400))
    (map-set proposals
      { proposal-id: proposal-id }
      {
        scientist: tx-sender,
        title: title,
        abstract: abstract,
        funding-goal: funding-goal,
        current-funding: u0,
        status: "proposed",
        ipfs-hash: none,
        reviewers: (list)
      }
    )
    (var-set proposal-counter (+ proposal-id u1))
    (ok proposal-id)
  )
)

(define-public (update-research-status (proposal-id uint) (ipfs-hash (string-utf8 46)))
  (let
    (
      (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) (err u404)))
    )
    (asserts! (is-eq tx-sender (get scientist proposal)) (err u403))
    (asserts! (is-eq (get status proposal) "funded") (err u400))
    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal {
        status: "in-progress",
        ipfs-hash: (some ipfs-hash)
      })
    )
    (ok true)
  )
)

(define-public (complete-research (proposal-id uint) (final-ipfs-hash (string-utf8 46)))
  (let
    (
      (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) (err u404)))
    )
    (asserts! (is-eq tx-sender (get scientist proposal)) (err u403))
    (asserts! (is-eq (get status proposal) "in-progress") (err u400))
    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal {
        status: "complete",
        ipfs-hash: (some final-ipfs-hash)
      })
    )
    (ok true)
  )
)

;; ====================
;; Funding functions
;; ====================

(define-public (fund-proposal (proposal-id uint))
  (let
    (
      (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) (err u404)))
      (amount (unwrap! (get-amount) (err u400)))
      (current-funding (get current-funding proposal))
      (funding-goal (get funding-goal proposal))
      (updated-funding (+ current-funding amount))
    )
    (asserts! (is-eq (get status proposal) "proposed") (err u400))
    (asserts! (>= amount u1000000) (err u400)) ;; Minimum 1 STX
    
    ;; Transfer STX from sender to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update funder records
    (map-set funders
      { proposal-id: proposal-id, funder: tx-sender }
      {
        amount: (default-to u0 (get amount (map-get? funders { proposal-id: proposal-id, funder: tx-sender }))) + amount
      }
    )
    
    ;; Update proposal funding
    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal {
        current-funding: updated-funding,
        status: (if (>= updated-funding funding-goal) "funded" "proposed")
      })
    )
    
    (ok updated-funding)
  )
)

(define-private (get-amount)
  (let ((amount (get-stx-amount?)))
    (if (is-some amount)
      (some (unwrap-panic amount))
      none
    )
  )
)

(define-private (get-stx-amount?)
  (contract-call? .stx get-call-amount)
)

;; ====================
;; Peer review functions
;; ====================

(define-public (assign-reviewers (proposal-id uint) (reviewers (list 5 principal)))
  (let
    (
      (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) (err u404)))
    )
    (asserts! (is-eq tx-sender (var-get admin)) (err u403))
    (asserts! (is-eq (get status proposal) "complete") (err u400))
    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal {
        reviewers: reviewers
      })
    )
    (ok true)
  )
)

(define-public (submit-review (proposal-id uint) (score uint) (comments (string-utf8 500)) (verified bool))
  (let
    (
      (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) (err u404)))
      (reviewers (get reviewers proposal))
    )
    (asserts! (is-some (index-of reviewers tx-sender)) (err u403))
    (asserts! (and (>= score u1) (<= score u10)) (err u400))
    
    (map-set peer-reviews
      { proposal-id: proposal-id, reviewer: tx-sender }
      {
        score: score,
        comments: comments,
        verified: verified
      }
    )
    
    ;; Check if sufficient verified reviews exist
    (if (check-sufficient-verification proposal-id)
      (begin
        (try! (mint-research-finding proposal-id))
        (map-set proposals
          { proposal-id: proposal-id }
          (merge proposal {
            status: "verified"
          })
        )
        (ok true)
      )
      (ok true)
    )
  )
)

(define-private (check-sufficient-verification (proposal-id uint))
  (let
    (
      (proposal (unwrap-panic (map-get? proposals { proposal-id: proposal-id })))
      (reviewers (get reviewers proposal))
      (verified-count (fold check-reviewer-verified u0 reviewers))
    )
    (>= verified-count u3) ;; Require at least 3 verified reviews
  )
)

(define-private (check-reviewer-verified (reviewer principal) (count uint))
  (let
    (
      (review (map-get? peer-reviews { proposal-id: (var-get proposal-counter), reviewer: reviewer }))
    )
    (if (and (is-some review) (get verified (unwrap-panic review)))
      (+ count u1)
      count
    )
  )
)

;; ====================
;; NFT functions
;; ====================

(define-private (mint-research-finding (proposal-id uint))
  (let
    (
      (proposal (unwrap-panic (map-get? proposals { proposal-id: proposal-id })))
      (scientist (get scientist proposal))
    )
    (nft-mint? research-findings proposal-id scientist)
  )
)

;; Get public information about a proposal
(define-read-only (get-proposal-info (proposal-id uint))
  (map-get? proposals { proposal-id: proposal-id })
)

;; Get funding information
(define-read-only (get-funding-info (proposal-id uint) (funder principal))
  (map-get? funders { proposal-id: proposal-id, funder: funder })
)

;; Get review information
(define-read-only (get-review-info (proposal-id uint) (reviewer principal))
  (map-get? peer-reviews { proposal-id: proposal-id, reviewer: reviewer })
)