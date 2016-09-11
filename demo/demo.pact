(define-keyset 'demo-admin (read-keyset "keyset"))

(module demo 'demo-admin

 (defun keys-all (count matched) (= count matched))

 (defun create-account (address)
   (insert 'demo-accounts address
         { "balance": 0.0, "amount": 0.0, "data": "Created account" }))

 (defun transfer (src dest amount)
   "transfer AMOUNT from SRC to DEST"
  (with-read 'demo-accounts src { "balance":= src-balance }
   (check-balance src-balance amount)
    (with-read 'demo-accounts dest { "balance":= dest-balance }
     (update 'demo-accounts src
            { "balance": (- src-balance amount), "amount": (- amount)
            , "data": { "transfer-to": dest } })
     (update 'demo-accounts dest
            { "balance": (+ dest-balance amount), "amount": amount
            , "data": { "transfer-from": src } }))))

 (defun read-account (id)
   "Read data for account ID"
   (read 'demo-accounts id 'balance 'amount 'data))

 (defun check-balance (balance amount)
   (enforce (<= amount balance) "Insufficient funds"))

 (defun fund-account (address amount)
   (update 'demo-accounts address
           { "balance": amount, "amount": amount
           , "data": "Admin account funding" }))

 (defun read-all ()
   { "Acct1": (read-account "Acct1")
   , "Acct2": (read-account "Acct2")})

)

(create-table 'demo-accounts 'demo)

(create-account "Acct1")
(fund-account "Acct1" 100000.0)
(create-account "Acct2")
