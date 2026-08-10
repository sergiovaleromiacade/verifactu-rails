# frozen_string_literal: true

module VerifactuRails
  module Libro
    # El esquema del libro registro, en una migración reutilizable: la usa el
    # generador de Rails y también la suite de tests, para que lo que se prueba
    # sea exactamente lo que se instala.
    #
    # ESTA CLASE ESTÁ CONGELADA. Es el esquema v1 y no se toca nunca más. La
    # migración que `rails g verifactu:install` deja en la app no copia el
    # esquema: hereda de aquí. Eso significa que cambiarlo mutaría el pasado —
    # una app que ya migró se quedaría con el esquema viejo mientras una
    # instalación nueva estrena el nuevo, las dos convencidas de estar al día.
    # Los cambios de esquema van en migraciones NUEVAS y aparte.
    #
    # Portable a PostgreSQL y MySQL: nada de índices parciales, de jsonb ni de
    # tipos propios de un motor. Lo único que se exige de la base de datos es que
    # sepa bloquear filas (SELECT ... FOR UPDATE) y respetar índices únicos.
    class Migracion < ActiveRecord::Migration[7.0]
      def change
        create_table :verifactu_cadenas do |t|
          # Una cadena por "SIF virtual". No lleva valor por defecto NI se genera
          # sola en ninguna parte: abrir una instalación es un acto deliberado de
          # quien despliega (ver doc/FUENTES.md).
          t.string :numero_instalacion, null: false, limit: 100
          t.string :nif_obligado,       null: false, limit: 9
          t.string :nombre_obligado,    null: false, limit: 120
          t.bigint :ultimo_registro_id
          t.datetime :no_enviar_antes_de
          t.timestamps

          t.index :numero_instalacion, unique: true
        end

        create_table :verifactu_registros do |t|
          t.references :cadena, null: false, index: false,
                                foreign_key: { to_table: :verifactu_cadenas }
          t.string :tipo, null: false, limit: 10 # alta | anulacion

          # Las ENTRADAS de la huella van como columnas, no enterradas en el
          # payload: son lo que permite recalcularla años después sin parsear
          # nada. Se guardan ya formateadas, con el mismo string que se serializó.
          t.string :id_emisor,        null: false, limit: 9
          t.string :num_serie,        null: false, limit: 60
          t.string :fecha_expedicion, null: false, limit: 10 # dd-mm-yyyy, canónico
          t.string :tipo_factura,     limit: 2   # null en las anulaciones
          t.string :cuota_total,      limit: 20
          t.string :importe_total,    limit: 20
          t.string :huella,           null: false, limit: 64

          # Centinela '' para el primer eslabón, NO null: en Postgres y en MySQL
          # dos NULL no colisionan en un índice único, así que con null se podría
          # colar más de un PrimerRegistro por cadena. Con '' no.
          t.string :huella_anterior, null: false, limit: 64, default: ''

          # El STRING exacto que entró en la huella, con su huso. Una columna
          # datetime normaliza a UTC y pierde el offset, y entonces la huella ya
          # no se puede recalcular.
          t.string :fecha_hora_gen, null: false, limit: 25

          # El fragmento XML del registro, ya construido y con su huella dentro.
          # Se guarda hecho, y no los argumentos con que se construyó, para que
          # lo que se envíe sea exactamente lo que se calculó: la huella y el XML
          # no pueden divergir si nadie los vuelve a derivar.
          t.text    :payload,         null: false
          t.integer :payload_version, null: false, default: 1
          t.text    :qr_url,          null: false
          t.text    :anomalias # JSON con los fallos del art. 7.i, o null
          t.string  :estado,          null: false, limit: 20, default: 'pendiente'
          t.string  :csv,             limit: 20
          t.integer :codigo_error
          t.text    :descripcion_error
          t.datetime :enviado_at
          t.timestamps

          # ESTE es el índice que impide bifurcar la cadena. Dos registros no
          # pueden compartir predecesor, pase lo que pase con el lock. Está
          # comprobado que la AEAT acepta una cadena bifurcada sin avisar, así
          # que esta restricción es la única red que hay.
          t.index %i[cadena_id huella_anterior], unique: true,
                                                 name: 'idx_verifactu_sin_bifurcacion'
          t.index %i[cadena_id huella], unique: true
          t.index %i[cadena_id estado id]

          # NO es único a propósito: una subsanación reutiliza el mismo IDFactura
          # deliberadamente, y así lo acepta la AEAT (comprobado).
          t.index %i[id_emisor num_serie fecha_expedicion], name: 'idx_verifactu_id_factura'
        end
      end
    end
  end
end
