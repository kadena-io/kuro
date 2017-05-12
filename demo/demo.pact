(define-keyset 'demo-admin (read-keyset "demo-admin-keyset"))

(module demo 'demo-admin

  (defschema account
    balance:decimal
    amount:decimal
    data)

  (deftable accounts:{account})

  (defun keys-all (count matched) (= count matched))

  (defun create-account (id init-bal)
    (insert accounts id
         { "balance": init-bal, "amount": init-bal, "data": "Created account" }))

  (defun transfer (src dest amount)
    "transfer AMOUNT from SRC to DEST"
    (with-read accounts src { "balance":= src-balance }
    (check-balance src-balance amount)
      (with-read accounts dest { "balance":= dest-balance }
      (update accounts src
              { "balance": (- src-balance amount), "amount": (- amount)
              , "data": { "transfer-to": dest } })
      (update accounts dest
              { "balance": (+ dest-balance amount), "amount": amount
              , "data": { "transfer-from": src } }))))

  (defpact payment (src dest amount)
    "Demo continuation-style payment, using 'Alice' and 'Bob' entities."
    (step-with-rollback
     "Alice"
     (with-read
         accounts src { "balance" := src-balance }
         (check-balance src-balance amount)
         (update accounts src
                 { "balance": (- src-balance amount), "amount": (- amount)
                 , "data": { "transfer-to": dest, "message": "Starting pact" } })
         (yield { "message": "Hi Bob" }))
     (with-read
         accounts src { "balance" := src-balance }
         (update accounts src
                 { "balance": (+ src-balance amount), "amount": amount
                 , "data": { "message": (format "rollback: {}" (pact-txid)) } })))
    (step
     "Bob"
     (with-read
         accounts dest { "balance" := dest-balance }
         (resume { "message":= message }
                 (update accounts dest
                         { "balance": (+ dest-balance amount), "amount": amount
                         , "data": { "transfer-from": src, "message": message } })))))

  (defun read-account (id)
    "Read data for account ID"
    (+ { "account": id } (read accounts id)))

  (defun check-balance (balance amount)
    (enforce (<= amount balance) "Insufficient funds"))

  (defun fund-account (address amount)
    (update accounts address
            { "balance": amount
            , "amount": amount
            , "data": "Admin account funding" }))

 (defun read-all ()
   (map (read-account) (keys accounts)))

)

(create-table accounts)

;;(create-account "Acct1")
;;(fund-account "Acct1" 1000000.0)
;;(create-account "Acct2")
