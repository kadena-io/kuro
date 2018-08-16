(define-keyset 'orders-admin-keyset (read-keyset "orders-admin-keyset"))

(module orders 'orders-admin-keyset

  (defschema order
    "Row type for orders table"
      id:string
      recordId:string
      recordHash:string
      recordDate:time
      createdBy:string
      comment:string
      createdOn:time
      lastUpdatedOn:time
      keyset:string)

  (deftable orders:{order}
    "Orders table")

  (defun create-order (orderId keyset recordId recordHash recordDate createdBy comment createdOn)
    "Create a new order"
    (insert orders orderId
      { "keyset": keyset,
        "id": orderId,
        "recordId": recordId,
        "recordHash": recordHash,
        "recordDate": recordDate,
        "createdBy": createdBy,
        "comment": comment,
        "createdOn": createdOn,
        "lastUpdatedOn": createdOn
      }))
)

(create-table orders) 