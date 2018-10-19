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

  (defun zero-pad-month (timeStr:string)
  "Converts space-padded month date to zero-padded"
    (parse-time "%m/%e/%y %k:%M"
      (if (!= (take -1 (take 3 timeStr)) "/") (+ "0" timeStr) timeStr)
    )
  )
  
  (defun batch-create-order (orderObj:object)
    "Creates new orders in batches"
    (create-order
      (at "id" orderObj)
      "key"
      (at "record_id" orderObj)
      (at "record_hash" orderObj)
      (zero-pad-month (at "created_on" orderObj))
      (at "created_by" orderObj)
      (at "comment" orderObj)
      (zero-pad-month (at "created_on" orderObj))
    )
  )
)

(create-table orders) 