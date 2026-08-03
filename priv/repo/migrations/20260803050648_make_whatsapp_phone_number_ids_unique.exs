defmodule Nila.Repo.Migrations.MakeWhatsappPhoneNumberIdsUnique do
  use Ecto.Migration

  def change do
    create unique_index(:integration_connections, [:external_account_id],
             where: "provider = 'whatsapp'",
             name: :integration_connections_whatsapp_phone_number_id_index
           )
  end
end
