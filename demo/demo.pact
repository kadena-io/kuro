(define-keyset 'demo-admin (read-keyset "demo-admin-keyset"))

(module demo 'demo-admin

  (defschema account
    balance:decimal
    amount:decimal
    data)

  (deftable accounts:{account})

  (defun create-account (id init-bal)
    (insert accounts id
         { "balance": init-bal, "amount": init-bal, "data": "Created account" }))

  (defun transfer (src dest amount)
    "transfer AMOUNT from SRC to DEST for unencrypted accounts"
    (debit src amount { "transfer-to": dest })
    (credit dest amount { "transfer-from": src }))

  (defpact payment (src dest amount)
    "Two-phase confidential payment, using 'Alice' and 'Bob' entities."
    (step-with-rollback
     "Alice"
     (let ((result (debit src amount { "transfer-to": dest, "message": "Starting pact" })))
       (yield { "result": result, "amount": amount }))
     (credit src amount { "rollback": (pact-txid) }))
    (step
     "Bob"
     (resume { "result":= result, "amount":= debit-amount }
       (credit dest debit-amount
               { "transfer-from": src, "debit-result": result }))))

  (defun debit (acct amount data)
    "Debit ACCT for AMOUNT, enforcing positive amount and sufficient funds, annotating with DATA"
    (enforce-positive amount)
    (with-read accounts acct { "balance":= balance }
      (check-balance balance amount)
      (update accounts acct
            { "balance": (- balance amount), "amount": (- amount)
            , "data": data })))

  (defun credit (acct amount data)
    "Credit ACCT for AMOUNT, enforcing positive amount"
    (enforce-positive amount)
    (with-read accounts acct { "balance":= balance }
      (update accounts acct
            { "balance": (+ balance amount), "amount": amount
            , "data": data })))


  (defun read-account (id)
    "Read data for account ID"
    (+ { "account": id } (read accounts id)))

  (defun check-balance (balance amount)
    (enforce (<= amount balance) "Insufficient funds"))

  (defun enforce-positive (amount)
    (enforce (>= amount 0.0) "amount must be positive"))

 (defun read-all ()
   (map (read-account) (keys accounts)))

 (defun create-global-accounts ()
   (create-account "Acct1" 1000000.0)
   (create-account "Acct2" 0.0)
   (read-all))

)

(create-table accounts)
