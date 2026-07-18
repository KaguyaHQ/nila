defmodule Nila.Repo.Migrations.AddChaseIdentityAndConsent do
  use Ecto.Migration

  def up do
    alter table(:clients) do
      add :email, :string
      add :chase_channel, :string, null: false, default: "none"
    end

    execute("""
    UPDATE clients
    SET phone = CASE
      WHEN regexp_replace(phone, '[^0-9]', '', 'g') = '' THEN NULL
      WHEN regexp_replace(phone, '[^0-9]', '', 'g') LIKE '00%'
        THEN substring(regexp_replace(phone, '[^0-9]', '', 'g') FROM 3)
      WHEN length(regexp_replace(phone, '[^0-9]', '', 'g')) = 11
        AND regexp_replace(phone, '[^0-9]', '', 'g') LIKE '0%'
        THEN '91' || substring(regexp_replace(phone, '[^0-9]', '', 'g') FROM 2)
      WHEN length(regexp_replace(phone, '[^0-9]', '', 'g')) = 10
        THEN '91' || regexp_replace(phone, '[^0-9]', '', 'g')
      ELSE regexp_replace(phone, '[^0-9]', '', 'g')
    END
    WHERE phone IS NOT NULL
    """)

    create unique_index(:clients, [:org_id, :phone],
             where: "phone IS NOT NULL",
             name: :clients_org_id_phone_index
           )

    alter table(:gst_chase_asks) do
      add :channel, :string, null: false, default: "manual"
      modify :sent_by_id, :bigint, null: true
    end
  end

  def down do
    execute("DELETE FROM gst_chase_asks WHERE sent_by_id IS NULL")

    alter table(:gst_chase_asks) do
      modify :sent_by_id, :bigint, null: false
      remove :channel
    end

    drop index(:clients, [:org_id, :phone], name: :clients_org_id_phone_index)

    alter table(:clients) do
      remove :chase_channel
      remove :email
    end
  end
end
