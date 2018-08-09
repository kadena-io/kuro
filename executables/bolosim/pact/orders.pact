(define-keyset 'orders-admin (read-keyset "orders-admin-keyset"))

(module orders 'orders-admin
  (defschema order
    "Row type for orders table"
      id:string
      recordId:string
      recordHash:string
      recordNpi:string
      recordRequisitionDate:time
      recordRequisitionChannel:string
      recordLast4OfTin:string
      isActive:bool
      createdBy:string
      comment:string
      createdOn:time
      lastUpdatedOn:time
      keyset:string)

  (deftable orders:{order}
    "Orders table")

  ;; import the accounts module
  (use 'accounts)

  ;; CREATE
  (defun create-order (orderId keyset recordId recordHash recordNpi recordRequisitionDate recordRequisitionChannel recordLast4OfTin createdBy comment createdOn)
    "Create a new order"
    (insert orders orderId
      { "keyset": keyset,
        "id": orderId,
        "recordId": recordId,
        "recordHash": recordHash,
        "recordNpi": recordNpi,
        "recordRequisitionDate": recordRequisitionDate,
        "recordRequisitionChannel": recordRequisitionChannel,
        "recordLast4OfTin": (take -4 recordLast4OfTin),
        "createdBy": createdBy,
        "comment": comment,
        "createdOn": createdOn,
        "lastUpdatedOn": createdOn,
        "isActive": true
      }))

  ;; UPDATE ORDER RECORD
  (defun update-order-record (orderId comment recordId recordHash recordRequisitionDate recordRequisitionChannel recordLast4OfTin lastUpdatedOn)
    "Update the order record"
    (with-read orders orderId { "keyset" := ks }
      (enforce-keyset ks))
    (update orders orderId {
      "comment": comment,
      "recordId": recordId,
      "recordHash": recordHash,
      "recordRequisitionDate": recordRequisitionDate,
      "recordRequisitionChannel": recordRequisitionChannel,
      "recordLast4OfTin": (take -4 recordLast4OfTin),
      "lastUpdatedOn": lastUpdatedOn })
  )

  ;; UPDATE ORDER
  (defun update-order (orderId isActive comment recordRequisitionDate recordRequisitionChannel lastUpdatedOn)
    "Update the order record"
    (with-read orders orderId { "keyset" := ks }
      (enforce-keyset ks))
    (update orders orderId {
      "isActive": isActive,
      "comment": comment,
      "recordRequisitionDate": recordRequisitionDate,
      "recordRequisitionChannel": recordRequisitionChannel,
      "lastUpdatedOn": lastUpdatedOn })
  )

  ;; PURCHASE A RECORD
  (defun execute-purchase-order (newOrderId keyset recordHashToPurchase purchasedBy comment purchasedOn buyerAccountId sellerAccountId)
    "Create order for purchased record and transfer money"
    (let ((toPurchase (at 0 (take 1 (reverse (sort ['lastUpdatedOn] (read-active-orders-by-hash recordHashToPurchase)))))))
      (create-order
        newOrderId
        keyset
        (at "recordId" toPurchase)
        (at "recordHash" toPurchase)
        (at "recordNpi" toPurchase)
        (at "recordRequisitionDate" toPurchase)
        (at "recordRequisitionChannel" toPurchase)
        (at "recordLast4OfTin" toPurchase)
        purchasedBy
        comment
        purchasedOn)

      (accounts.transfer buyerAccountId sellerAccountId 1.0 purchasedOn)
    )
  )

  ;; DEACTIVATE
  (defun deactivate-order-by-id (id:string)
      "Inactivate an order"
      (deactivate-order (read-order-by-id id)))

  (defun deactivate-order (order:object{order})
    (update orders (at "id" order) { "isActive" : false }))

  ;; READ
  (defun get-transactions-for-order (id)
    (keylog orders id 0))

  (defun read-order-npis ()
    (map (at "recordNpi") (select orders ["recordNpi"] (where "recordNpi" (!= ""))))
  )

  (defun read-order-by-id (id)
    (read orders id))

  (defun read-order-by-id-with-projection (id projection)
    (read orders id projection))

  (defun read-orders ()
    "Read all orders"
    (map (read orders) (keys orders)))

  (defun read-orders-by-npi (npi isActive)
    "Read orders by NPI, isActive"
    (select orders (and? (wildcard-match-bool 'isActive isActive)
                         (wildcard-match 'recordNpi npi)))
  )

  (defun read-active-orders-by-hash (recordHash)
    "Read active orders by hash"
    (select orders (and?  (order-is-active true)
                          (is-hash-match recordHash)))
  )

  (defun is-hash-match (hash order:object{order})
    "returns true if order.recordHash matches hash"
    (= hash (at "recordHash" order))
  )

  (defun read-orders-filter (isActive createdBy recordIds recordHash)
    "Read all orders filtered to equal matched fields in SEARCHOBJ"
    (select orders
      (and? (and? (and? (wildcard-match-bool 'isActive isActive)
                        (wildcard-match 'createdBy createdBy))
                  (list-contains-match "recordId" recordIds))
            (wildcard-match 'recordHash recordHash))))

  (defun order-is-active (isActive:bool order:object{order})
    "return order is order.isActive matches given isActive"
    (= isActive (at "isActive" order)))

  (defconst ANY "*" "Wildcard value for 'read-orders-filter' method")

  (defun wildcard-match (field:string value:string order:object{order})
    (or (= value ANY) (= value (at field order))))

  (defun wildcard-match-bool (field:string value order:object{order})
    (or (= value ANY) (= (= value true) (at field order))))

  (defun list-contains-match (field:string values order:object{order})
    (or (= values ANY) (contains (at field order) values)))
)
