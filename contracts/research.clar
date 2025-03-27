;; GENESIS - Digital Asset Registry Smart Contract

;; Manages unique digital asset registrations with ownership tracking and metadata management

;; Custom Error Codes
(define-constant ERROR-UNAUTHORIZED-ACTION (err u2000))
(define-constant ERROR-INVALID-ASSET-HASH (err u2001))
(define-constant ERROR-ASSET-ALREADY-EXISTS (err u2002))
(define-constant ERROR-ASSET-NOT-FOUND (err u2003))
(define-constant ERROR-INVALID-ASSET-ID (err u2004))
(define-constant ERROR-ASSET-EXPIRED (err u2005))
(define-constant ERROR-INVALID-EXPIRATION (err u2006))

;; Contract Owner
(define-data-var contract-administrator principal tx-sender)

;; Asset Registration Tracking
(define-map digital-asset-registry
  { asset-id: uint }
  { creator: principal, registration-time: uint, asset-hash: (buff 32), expiration: (optional uint) }
)

;; Hash Uniqueness Tracking
(define-map registered-asset-hashes
  { hash: (buff 32) }
  { asset-id: uint }
)

;; Asset ID Counter
(define-data-var asset-id-sequence uint u0)

;; Asset Registration Function
(define-public (register-digital-asset 
  (asset-hash (buff 32)) 
  (optional-expiration (optional uint))
)
  (begin
    ;; Validate input
    (asserts! (is-eq (len asset-hash) u32) ERROR-INVALID-ASSET-HASH)
    (asserts! (not (is-eq asset-hash 0x0000000000000000000000000000000000000000000000000000000000000000)) 
              ERROR-INVALID-ASSET-HASH)
    (asserts! (is-none (map-get? registered-asset-hashes { hash: asset-hash })) 
              ERROR-ASSET-ALREADY-EXISTS)
    
    ;; Optional expiration validation
    (asserts! (match optional-expiration
               expiry (> expiry block-height)
               true)
              ERROR-INVALID-EXPIRATION)
    
    (let 
      (
        (new-asset-id (+ (var-get asset-id-sequence) u1))
      )
      ;; Record asset registration
      (map-set digital-asset-registry 
        { asset-id: new-asset-id }
        { 
          creator: tx-sender, 
          registration-time: block-height, 
          asset-hash: asset-hash, 
          expiration: optional-expiration 
        }
      )
      
      ;; Track hash uniqueness
      (map-set registered-asset-hashes 
        { hash: asset-hash }
        { asset-id: new-asset-id }
      )
      
      ;; Update asset ID sequence
      (var-set asset-id-sequence new-asset-id)
      
      (ok new-asset-id)
    )
  )
)

;; Asset Transfer Function
(define-public (transfer-asset-ownership 
  (asset-id uint) 
  (new-owner principal)
)
  (let 
    (
      (current-max-id (var-get asset-id-sequence))
      (asset-data (map-get? digital-asset-registry { asset-id: asset-id }))
    )
    ;; Validate inputs
    (asserts! (<= asset-id current-max-id) ERROR-INVALID-ASSET-ID)
    (asserts! (> asset-id u0) ERROR-INVALID-ASSET-ID)
    (asserts! (is-some asset-data) ERROR-ASSET-NOT-FOUND)
    
    (let 
      (
        (asset-details (unwrap-panic asset-data))
        (current-time block-height)
      )
      ;; Check ownership and expiration
      (asserts! (is-eq tx-sender (get creator asset-details)) ERROR-UNAUTHORIZED-ACTION)
      (asserts! (or
                  (is-none (get expiration asset-details))
                  (< current-time (unwrap-panic (get expiration asset-details)))
                )
                ERROR-ASSET-EXPIRED)
      
      ;; Update ownership
      (map-set digital-asset-registry
        { asset-id: asset-id }
        (merge asset-details { creator: new-owner })
      )
      
      (ok true)
    )
  )
)

;; Asset Metadata Update Function
(define-public (update-asset-metadata 
  (asset-id uint) 
  (new-hash (buff 32))
)
  (let 
    (
      (current-max-id (var-get asset-id-sequence))
      (asset-data (map-get? digital-asset-registry { asset-id: asset-id }))
    )
    ;; Validate inputs
    (asserts! (<= asset-id current-max-id) ERROR-INVALID-ASSET-ID)
    (asserts! (> asset-id u0) ERROR-INVALID-ASSET-ID)
    (asserts! (is-eq (len new-hash) u32) ERROR-INVALID-ASSET-HASH)
    (asserts! (is-some asset-data) ERROR-ASSET-NOT-FOUND)
    
    (let 
      (
        (asset-details (unwrap-panic asset-data))
        (current-time block-height)
      )
      ;; Check ownership and expiration
      (asserts! (is-eq tx-sender (get creator asset-details)) ERROR-UNAUTHORIZED-ACTION)
      (asserts! (or
                  (is-none (get expiration asset-details))
                  (< current-time (unwrap-panic (get expiration asset-details)))
                )
                ERROR-ASSET-EXPIRED)
      
      ;; Remove old hash tracking
      (map-delete registered-asset-hashes { hash: (get asset-hash asset-details) })
      
      ;; Update asset details
      (map-set digital-asset-registry
        { asset-id: asset-id }
        (merge asset-details { asset-hash: new-hash })
      )
      
      ;; Track new hash
      (map-set registered-asset-hashes
        { hash: new-hash }
        { asset-id: asset-id }
      )
      
      (ok true)
    )
  )
)

;; Asset Expiration Extension Function
(define-public (extend-asset-registration 
  (asset-id uint) 
  (new-expiration uint)
)
  (let 
    (
      (current-max-id (var-get asset-id-sequence))
      (asset-data (map-get? digital-asset-registry { asset-id: asset-id }))
    )
    ;; Validate inputs
    (asserts! (<= asset-id current-max-id) ERROR-INVALID-ASSET-ID)
    (asserts! (> asset-id u0) ERROR-INVALID-ASSET-ID)
    (asserts! (> new-expiration block-height) ERROR-INVALID-EXPIRATION)
    (asserts! (is-some asset-data) ERROR-ASSET-NOT-FOUND)
    
    (let 
      (
        (asset-details (unwrap-panic asset-data))
      )
      ;; Check ownership
      (asserts! (is-eq tx-sender (get creator asset-details)) ERROR-UNAUTHORIZED-ACTION)
      
      ;; Update expiration
      (map-set digital-asset-registry
        { asset-id: asset-id }
        (merge asset-details { expiration: (some new-expiration) })
      )
      
      (ok true)
    )
  )
)
