;; gasless-swap.clar 
;; A gasless DEX with meta-transactions allowing users to trade without holding STX for gas fees

;; Define SIP-010 token trait
(define-trait sip-010-trait
    (
        ;; Transfer from the caller to a new principal
        (transfer (uint principal principal (optional (buff 34))) (response bool uint))
        
        ;; the human-readable name of the token
        (get-name () (response (string-ascii 32) uint))
        
        ;; the ticker symbol, or empty if none
        (get-symbol () (response (string-ascii 32) uint))
        
        ;; the number of decimals used, e.g. 6 would mean 1_000_000 represents 1 token
        (get-decimals () (response uint uint))
        
        ;; the balance of the passed principal
        (get-balance (principal) (response uint uint))
        
        ;; the current total supply (which does not need to be a constant)
        (get-total-supply () (response uint uint))
        
        ;; an optional URI that represents metadata of this token
        (get-token-uri () (response (optional (string-utf8 256)) uint))
    )
)

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-NONCE (err u101))
(define-constant ERR-SLIPPAGE (err u102))
(define-constant ERR-INSUFFICIENT-LIQUIDITY (err u103))
(define-constant ERR-IDENTICAL-TOKENS (err u104))
(define-constant ERR-ZERO-AMOUNT (err u105))
(define-constant ERR-INSUFFICIENT-BALANCE (err u106))
(define-constant ERR-POOL-EXISTS (err u107))
(define-constant ERR-POOL-NOT-EXISTS (err u108))
(define-constant ERR-INVALID-SIGNATURE (err u109))

(define-constant FEE-DENOMINATOR u10000)
(define-constant PROTOCOL-FEE u30) ;; 0.3% protocol fee
(define-constant FEE-MULTIPLIER u9970) ;; FEE-DENOMINATOR - PROTOCOL-FEE

;; Data storage - using a simpler key structure
(define-map pools {token-a: principal, token-b: principal} (tuple (reserve-a uint) (reserve-b uint) (total-supply uint)))
(define-map balances principal uint) ;; LP token balances
(define-map user-nonces principal uint) ;; Tracks used nonces per user for meta-transactions

;; Events
(define-data-var swap-event (optional (tuple (user principal) (token-in principal) (token-out principal) (amount-in uint) (amount-out uint))) none)
(define-data-var liquidity-event (optional (tuple (provider principal) (token-a principal) (token-b principal) (amount-a uint) (amount-b uint) (lp-amount uint))) none)

;; Simple integer square root approximation using Newton's method
(define-private (sqrt-approx (n uint))
    (if (<= n u1)
        n
        (let ((x n))
            ;; Simple approximation - start with n/2 and iterate a few times
            (let ((guess (/ n u2)))
                (let ((better-guess (/ (+ guess (/ n guess)) u2)))
                    (let ((final-guess (/ (+ better-guess (/ n better-guess)) u2)))
                        final-guess
                    )
                )
            )
        )
    )
)

;; Calculate the output amount based on constant product formula
(define-private (calculate-output-amount
    (reserve-in uint)
    (reserve-out uint)
    (amount-in uint)
)
    (if (or (is-eq amount-in u0) (is-eq reserve-in u0) (is-eq reserve-out u0))
        u0
        (let (
            (amount-in-with-fee (* amount-in FEE-MULTIPLIER))
            (numerator (* amount-in-with-fee reserve-out))
            (denominator (+ (* reserve-in FEE-DENOMINATOR) amount-in-with-fee))
        )
            (if (is-eq denominator u0)
                u0
                (/ numerator denominator)
            )
        )
    )
)

;; Verify ECDSA signature for meta-transactions
(define-private (verify-signature
    (message (buff 32))
    (signature (buff 65))
    (public-key (buff 33))
    (user principal)
)
    (match (secp256k1-recover? message signature)
        success (is-eq success public-key)
        error false
    )
)

;; Get the pool key - simple tuple approach
(define-private (get-pool-key
    (token-a <sip-010-trait>)
    (token-b <sip-010-trait>)
)
    {token-a: (contract-of token-a), token-b: (contract-of token-b)}
)

;; Public functions

;; Add liquidity to a pool
(define-public (add-liquidity
    (token-a <sip-010-trait>)
    (token-b <sip-010-trait>)
    (amount-a-desired uint)
    (amount-b-desired uint)
    (amount-a-min uint)
    (amount-b-min uint)
)
    (let (
        (pool-key (get-pool-key token-a token-b))
        (pool (map-get? pools pool-key))
    )
        (asserts! (not (is-eq token-a token-b)) ERR-IDENTICAL-TOKENS)
        (asserts! (and (> amount-a-desired u0) (> amount-b-desired u0)) ERR-ZERO-AMOUNT)
        
        (if (is-none pool)
            ;; Create new pool
            (let (
                (total-supply (sqrt-approx (* amount-a-desired amount-b-desired)))
            )
                (asserts! (> total-supply u0) ERR-INSUFFICIENT-LIQUIDITY)
                
                ;; Transfer tokens from user to contract
                (try! (contract-call? token-a transfer amount-a-desired tx-sender (as-contract tx-sender) none))
                (try! (contract-call? token-b transfer amount-b-desired tx-sender (as-contract tx-sender) none))
                
                ;; Create pool and mint LP tokens
                (map-set pools pool-key (tuple 
                    (reserve-a amount-a-desired)
                    (reserve-b amount-b-desired)
                    (total-supply total-supply)
                ))
                (map-set balances tx-sender total-supply)
                
                ;; Emit event
                (var-set liquidity-event (some (tuple
                    (provider tx-sender)
                    (token-a (contract-of token-a))
                    (token-b (contract-of token-b))
                    (amount-a amount-a-desired)
                    (amount-b amount-b-desired)
                    (lp-amount total-supply)
                )))
                
                (ok (tuple (amount-a amount-a-desired) (amount-b amount-b-desired) (liquidity total-supply)))
            )
            ;; Add to existing pool
            (let (
                (pool-data (unwrap-panic pool))
                (reserve-a (get reserve-a pool-data))
                (reserve-b (get reserve-b pool-data))
                (total-supply (get total-supply pool-data))
                (amount-b-optimal (/ (* amount-a-desired reserve-b) reserve-a))
            )
                (if (<= amount-b-optimal amount-b-desired)
                    (let (
                        (final-amount-a amount-a-desired)
                        (final-amount-b amount-b-optimal)
                    )
                        (asserts! (and (>= final-amount-a amount-a-min) (>= final-amount-b amount-b-min)) ERR-SLIPPAGE)
                        
                        ;; Transfer tokens from user to contract
                        (try! (contract-call? token-a transfer final-amount-a tx-sender (as-contract tx-sender) none))
                        (try! (contract-call? token-b transfer final-amount-b tx-sender (as-contract tx-sender) none))
                        
                        ;; Mint LP tokens proportional to contribution
                        (let (
                            (liquidity (/ (* final-amount-a total-supply) reserve-a))
                        )
                            (map-set pools pool-key (tuple
                                (reserve-a (+ reserve-a final-amount-a))
                                (reserve-b (+ reserve-b final-amount-b))
                                (total-supply (+ total-supply liquidity))
                            ))
                            (map-set balances tx-sender (+ (default-to u0 (map-get? balances tx-sender)) liquidity))
                            
                            ;; Emit event
                            (var-set liquidity-event (some (tuple
                                (provider tx-sender)
                                (token-a (contract-of token-a))
                                (token-b (contract-of token-b))
                                (amount-a final-amount-a)
                                (amount-b final-amount-b)
                                (lp-amount liquidity)
                            )))
                            
                            (ok (tuple (amount-a final-amount-a) (amount-b final-amount-b) (liquidity liquidity)))
                        )
                    )
                    (let (
                        (final-amount-a (/ (* amount-b-desired reserve-a) reserve-b))
                        (final-amount-b amount-b-desired)
                    )
                        (asserts! (and (>= final-amount-a amount-a-min) (>= final-amount-b amount-b-min)) ERR-SLIPPAGE)
                        
                        ;; Transfer tokens from user to contract
                        (try! (contract-call? token-a transfer final-amount-a tx-sender (as-contract tx-sender) none))
                        (try! (contract-call? token-b transfer final-amount-b tx-sender (as-contract tx-sender) none))
                        
                        ;; Mint LP tokens
                        (let (
                            (liquidity (/ (* final-amount-b total-supply) reserve-b))
                        )
                            (map-set pools pool-key (tuple
                                (reserve-a (+ reserve-a final-amount-a))
                                (reserve-b (+ reserve-b final-amount-b))
                                (total-supply (+ total-supply liquidity))
                            ))
                            (map-set balances tx-sender (+ (default-to u0 (map-get? balances tx-sender)) liquidity))
                            
                            ;; Emit event
                            (var-set liquidity-event (some (tuple
                                (provider tx-sender)
                                (token-a (contract-of token-a))
                                (token-b (contract-of token-b))
                                (amount-a final-amount-a)
                                (amount-b final-amount-b)
                                (lp-amount liquidity)
                            )))
                            
                            (ok (tuple (amount-a final-amount-a) (amount-b final-amount-b) (liquidity liquidity)))
                        )
                    )
                )
            )
        )
    )
)

;; Remove liquidity from a pool
(define-public (remove-liquidity
    (token-a <sip-010-trait>)
    (token-b <sip-010-trait>)
    (liquidity uint)
    (amount-a-min uint)
    (amount-b-min uint)
)
    (let (
        (pool-key (get-pool-key token-a token-b))
        (pool (map-get? pools pool-key))
    )
        (asserts! (not (is-none pool)) ERR-POOL-NOT-EXISTS)
        (asserts! (> liquidity u0) ERR-ZERO-AMOUNT)
        
        (let (
            (pool-data (unwrap-panic pool))
            (reserve-a (get reserve-a pool-data))
            (reserve-b (get reserve-b pool-data))
            (total-supply (get total-supply pool-data))
            (user-balance (default-to u0 (map-get? balances tx-sender)))
        )
            (asserts! (<= liquidity user-balance) ERR-INSUFFICIENT-BALANCE)
            
            ;; Calculate amounts to return
            (let (
                (amount-a (/ (* liquidity reserve-a) total-supply))
                (amount-b (/ (* liquidity reserve-b) total-supply))
            )
                (asserts! (and (>= amount-a amount-a-min) (>= amount-b amount-b-min)) ERR-SLIPPAGE)
                
                ;; Burn LP tokens
                (map-set balances tx-sender (- user-balance liquidity))
                
                ;; Update pool reserves
                (map-set pools pool-key (tuple
                    (reserve-a (- reserve-a amount-a))
                    (reserve-b (- reserve-b amount-b))
                    (total-supply (- total-supply liquidity))
                ))
                
                ;; Transfer tokens back to user
                (try! (contract-call? token-a transfer amount-a (as-contract tx-sender) tx-sender none))
                (try! (contract-call? token-b transfer amount-b (as-contract tx-sender) tx-sender none))
                
                ;; Emit event
                (var-set liquidity-event (some (tuple
                    (provider tx-sender)
                    (token-a (contract-of token-a))
                    (token-b (contract-of token-b))
                    (amount-a amount-a)
                    (amount-b amount-b)
                    (lp-amount liquidity)
                )))
                
                (ok (tuple (amount-a amount-a) (amount-b amount-b)))
            )
        )
    )
)

;; Gasless swap function using meta-transactions
(define-public (swap-tokens-for-tokens
    (token-in <sip-010-trait>)
    (token-out <sip-010-trait>)
    (amount-in uint)
    (min-amount-out uint)
    (nonce uint)
    (signature (buff 65))
    (public-key (buff 33))
)
    (let (
        (user tx-sender) ;; The relayer is the immediate sender
        (pool-key (get-pool-key token-in token-out))
        (pool (map-get? pools pool-key))
    )
        (asserts! (not (is-none pool)) ERR-POOL-NOT-EXISTS)
        (asserts! (not (is-eq token-in token-out)) ERR-IDENTICAL-TOKENS)
        (asserts! (> amount-in u0) ERR-ZERO-AMOUNT)
        
        ;; Verify nonce hasn't been used
        (let ((used-nonce (map-get? user-nonces user)))
            (asserts! (is-none used-nonce) ERR-INVALID-NONCE)
            (map-set user-nonces user nonce)
        )
        
        ;; Create message hash for signature verification (simplified)
        (let (
            ;; Simple message hash from key parameters
            (message-hash (sha256 (concat 
                (concat (unwrap-panic (to-consensus-buff? nonce)) 
                        (unwrap-panic (to-consensus-buff? amount-in)))
                (unwrap-panic (to-consensus-buff? min-amount-out)))))
        )
            (asserts! (verify-signature message-hash signature public-key user) ERR-INVALID-SIGNATURE)
        )
        
        (let (
            (pool-data (unwrap-panic pool))
            (reserve-in (get reserve-a pool-data))
            (reserve-out (get reserve-b pool-data))
        )
            ;; Calculate output amount
            (let ((amount-out (calculate-output-amount reserve-in reserve-out amount-in)))
                (asserts! (>= amount-out min-amount-out) ERR-SLIPPAGE)
                (asserts! (and (< amount-in reserve-in) (< amount-out reserve-out)) ERR-INSUFFICIENT-LIQUIDITY)
                
                ;; Transfer input tokens from user to contract
                (try! (contract-call? token-in transfer amount-in user (as-contract tx-sender) none))
                
                ;; Update pool reserves
                (map-set pools pool-key (tuple
                    (reserve-a (+ reserve-in amount-in))
                    (reserve-b (- reserve-out amount-out))
                    (total-supply (get total-supply pool-data))
                ))
                
                ;; Transfer output tokens to user
                (try! (contract-call? token-out transfer amount-out (as-contract tx-sender) user none))
                
                ;; Emit event
                (var-set swap-event (some (tuple
                    (user user)
                    (token-in (contract-of token-in))
                    (token-out (contract-of token-out))
                    (amount-in amount-in)
                    (amount-out amount-out)
                )))
                
                (ok (tuple (amount-in amount-in) (amount-out amount-out)))
            )
        )
    )
)

;; Regular swap function for users with STX
(define-public (swap
    (token-in <sip-010-trait>)
    (token-out <sip-010-trait>)
    (amount-in uint)
    (min-amount-out uint)
)
    (let (
        (pool-key (get-pool-key token-in token-out))
        (pool (map-get? pools pool-key))
    )
        (asserts! (not (is-none pool)) ERR-POOL-NOT-EXISTS)
        (asserts! (not (is-eq token-in token-out)) ERR-IDENTICAL-TOKENS)
        (asserts! (> amount-in u0) ERR-ZERO-AMOUNT)
        
        (let (
            (pool-data (unwrap-panic pool))
            (reserve-in (get reserve-a pool-data))
            (reserve-out (get reserve-b pool-data))
        )
            ;; Calculate output amount
            (let ((amount-out (calculate-output-amount reserve-in reserve-out amount-in)))
                (asserts! (>= amount-out min-amount-out) ERR-SLIPPAGE)
                (asserts! (and (< amount-in reserve-in) (< amount-out reserve-out)) ERR-INSUFFICIENT-LIQUIDITY)
                
                ;; Transfer input tokens from user to contract
                (try! (contract-call? token-in transfer amount-in tx-sender (as-contract tx-sender) none))
                
                ;; Update pool reserves
                (map-set pools pool-key (tuple
                    (reserve-a (+ reserve-in amount-in))
                    (reserve-b (- reserve-out amount-out))
                    (total-supply (get total-supply pool-data))
                ))
                
                ;; Transfer output tokens to user
                (try! (contract-call? token-out transfer amount-out (as-contract tx-sender) tx-sender none))
                
                ;; Emit event
                (var-set swap-event (some (tuple
                    (user tx-sender)
                    (token-in (contract-of token-in))
                    (token-out (contract-of token-out))
                    (amount-in amount-in)
                    (amount-out amount-out)
                )))
                
                (ok (tuple (amount-in amount-in) (amount-out amount-out)))
            )
        )
    )
)

;; View functions

;; Get pool reserves
(define-read-only (get-reserves
    (token-a <sip-010-trait>)
    (token-b <sip-010-trait>)
)
    (let (
        (pool-key (get-pool-key token-a token-b))
        (pool (map-get? pools pool-key))
    )
        (if (is-none pool)
            (ok none)
            (ok (some (unwrap-panic pool)))
        )
    )
)

;; Get user's LP token balance
(define-read-only (get-balance
    (user principal)
)
    (ok (default-to u0 (map-get? balances user)))
)

;; Get quote for swap
(define-read-only (get-amount-out
    (token-in <sip-010-trait>)
    (token-out <sip-010-trait>)
    (amount-in uint)
)
    (let (
        (pool-key (get-pool-key token-in token-out))
        (pool (map-get? pools pool-key))
    )
        (if (is-none pool)
            (err ERR-POOL-NOT-EXISTS)
            (let (
                (pool-data (unwrap-panic pool))
                (reserve-in (get reserve-a pool-data))
                (reserve-out (get reserve-b pool-data))
            )
                (ok (calculate-output-amount reserve-in reserve-out amount-in))
            )
        )
    )
)

;; Check if nonce has been used
(define-read-only (is-nonce-used
    (user principal)
    (nonce uint)
)
    (let ((used-nonce (map-get? user-nonces user)))
        (if (is-none used-nonce)
            (ok false)
            (ok (is-eq (unwrap-panic used-nonce) nonce))
        )
    )
)