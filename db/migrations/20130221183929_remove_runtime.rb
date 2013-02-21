# Copyright (c) 2009-2012 VMware, Inc.

Sequel.migration do
  change do
    drop_column :apps, :runtime_id
    drop_table :runtimes
  end
end
