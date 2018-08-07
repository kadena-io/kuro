(define-keyset 'accounts-admin (read-keyset "accounts-admin-keyset"))

(module accounts 'accounts-admin
  "Simple account functionality."
  (defschema account
    "Row type for accounts table."
    keyset:keyset
    id:string
    owner:string
    balance:decimal
    createdDate:time
    lastModifiedDate:time
    )

  (deftable accounts:{account}
    "Main table for accounts module.")

  (defun read-all-accounts-admin ()
    "Read all accounts"
    (enforce-keyset 'accounts-admin-keyset)
    (map (read accounts) (keys accounts)))

  (defun read-account (id)
    "Read data for account ID"
    (with-read accounts id
              { "keyset" := ks }
      (enforce-keyset ks)
      (read accounts id)
      ))

  (defun read-all-accounts-admin-for-owner (owner:string)
    "Read all accounts for given user"
    (filter (match-owner owner) (read-all-accounts-admin)))

  (defun read-account-owner (owner)
    "Read account for given user"
    (read-account (at "id" (at 0 (read-all-accounts-admin-for-owner owner)))))

  (defun create-account (accountId keyset balance owner createdDate lastModifiedDate)
    "Create an account if owner does not already have one"
    (insert accounts accountId
      { "id":accountId
      , "keyset":keyset
      , "balance":balance
      , "owner":owner
      , "createdDate":createdDate
      , "lastModifiedDate":lastModifiedDate
      }
    ))

  (defun match-owner (owner:string account:object{account})
    (= (at "owner" account) owner))

  (defun transfer (src dest amount date)
    "transfer AMOUNT from SRC to DEST"
    (with-read accounts src { "balance":= src-balance
                            , "keyset" := src-ks }
      (enforce (>= src-balance amount) "Insufficient funds")
      (enforce-keyset src-ks)
      (update accounts src
              { "balance": (- src-balance amount)
              , "lastModifiedDate": date
              }
      )
      (with-read accounts dest { "balance":= dest-balance }
        (update accounts dest
                { "balance": (+ dest-balance amount)
                , "lastModifiedDate": date
                }
        ))))
)
