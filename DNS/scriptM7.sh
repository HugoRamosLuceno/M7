#!/bin/bash
set -e

# Cambia la distribución del teclado a español.
setxkbmap es

# Script de configuración de red y DNS con BIND9.
# Se ejecuta como usuario normal; sudo se utiliza cuando hacen falta permisos de administrador.

# Solicita la contraseña de sudo al principio para evitar interrupciones posteriores.
sudo -v || { echo "Se necesitan permisos de sudo."; exit 1; }

# ---------- CONFIGURACIÓN FIJA ----------
# Nombre de la interfaz de red que se va a configurar.
IFACE="eno1"

# Servidor DNS al que BIND9 reenviará las consultas que no pueda resolver directamente.
FORWARDER="192.168.99.99"

# ---------- VALORES PREDETERMINADOS ----------
# Se usan como alternativa si no se puede detectar una IP o si se pulsa Enter en las preguntas.
DEF_IP="192.168.106.17"
DEF_NETMASK="255.255.0.0"
DEF_GATEWAY="192.168.88.88"
DEF_ZONE="hramos.cat"

# ---------- FUNCIÓN PARA PEDIR DATOS ----------
# Muestra un valor predeterminado. Si el usuario pulsa Enter, devuelve ese valor.
ask() {
    local prompt="$1" default="$2" answer=""
    read -r -p "$prompt [$default]: " answer
    echo "${answer:-$default}"
}

# Función especial para la IP para permitir dejarla vacía (sin valor por defecto si se fuerza vacío)
ask_ip() {
    local prompt="$1" default="$2" answer=""
    read -r -p "$prompt [$default]: " answer
    echo "${answer:-$default}"
}

# ---------- 1. INSTALAR PAQUETES ----------
# Actualiza la lista de paquetes e instala BIND9, herramientas DNS, Nmap y Flameshot.
echo ">>> Instalando paquetes..."
sudo apt update
sudo apt install -y bind9 dnsutils nmap flameshot

# ---------- 2. DETECTAR LA IP ACTUAL ----------
# Busca la primera dirección IPv4 global asignada a la interfaz indicada en IFACE.
CURRENT_IP=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null |
    awk 'NR == 1 { split($4, address, "/"); print address[1] }')

# Si la interfaz no tiene una IPv4 detectada, utiliza la IP predeterminada como alternativa.
if [[ -z "$CURRENT_IP" ]]; then
    echo "AVISO: No se ha detectado ninguna IPv4 en $IFACE."
    echo "Se utilizará la IP alternativa: $DEF_IP"
    CURRENT_IP="$DEF_IP"
fi

# ---------- 3. PEDIR LOS DATOS DE CONFIGURACIÓN ----------
# La IP detectada aparece como valor predeterminado; pulsar Enter la conserva.
echo
IP=$(ask_ip "Dirección IP (déjala en blanco o pulsa Enter para la por defecto)" "$DEF_IP")
NETMASK=$(ask "Máscara de red" "$DEF_NETMASK")
GATEWAY=$(ask "Puerta de enlace" "$DEF_GATEWAY")
ZONE=$(ask "Nombre de la zona DNS" "$DEF_ZONE")

echo
echo "Configuración seleccionada:"
echo "  Interfaz: $IFACE"
echo "  IP:       ${IP:-[No configurada / Omitida]}"
echo "  Máscara:  $NETMASK"
echo "  Gateway:  $GATEWAY"
echo "  Zona:     $ZONE"
echo

# ---------- 4. CONFIGURAR /etc/network/interfaces (Solo si se ha indicado IP) ----------
if [[ -n "$IP" ]]; then
    # Guarda una copia del archivo actual antes de modificarlo.
    sudo cp /etc/network/interfaces /etc/network/interfaces.bak

    # Sobrescribe la configuración de interfaces con la IP elegida
    sudo tee /etc/network/interfaces > /dev/null <<EOF
auto lo
iface lo inet loopback

auto $IFACE
iface $IFACE inet static
    address $IP
    netmask $NETMASK
    gateway $GATEWAY
EOF

    # Detiene el servicio de red, espera 7 segundos y lo vuelve a iniciar
    sudo systemctl stop networking
    echo ">>> Reiniciando networking (espera de 7 segundos)..."
    sleep 7
    sudo systemctl restart networking
else
    echo ">>> Omitiendo configuración de red (/etc/network/interfaces y systemctl networking) por no haberse especificado IP."
fi

# ---------- 5. CONFIGURAR /etc/resolv.conf ----------
# Guarda una copia del archivo DNS actual.
sudo cp /etc/resolv.conf /etc/resolv.conf.bak

# Si hay IP configurada la usa, si no, omite o deja el resolv.conf según proceda (aquí usa la IP si existe, o puedes ajustarlo)
RESOLV_IP="${IP:-$DEF_IP}"
sudo tee /etc/resolv.conf > /dev/null <<EOF
nameserver $RESOLV_IP
EOF

# ---------- 6. CONFIGURAR LAS OPCIONES DE BIND9 ----------
sudo cp /etc/bind/named.conf.options /etc/bind/named.conf.options.bak

sudo tee /etc/bind/named.conf.options > /dev/null <<EOF
options {
    directory "/var/cache/bind";
    forwarders {
        $FORWARDER;
    };
};
EOF

# ---------- 7. DECLARAR LA ZONA DNS ----------
sudo cp /etc/bind/named.conf.local /etc/bind/named.conf.local.bak

sudo tee -a /etc/bind/named.conf.local > /dev/null <<EOF

zone $ZONE {
    type master;
    file "/etc/bind/db.$ZONE";
};
EOF

# ---------- 8. CREAR EL ARCHIVO DE LA ZONA DNS ----------
# Usa la IP configurada o la por defecto para los registros de zona
ZONE_IP="${IP:-$DEF_IP}"
sudo tee "/etc/bind/db.$ZONE" > /dev/null <<EOF
\$TTL 1w

@   IN  SOA dns1.$ZONE. hugo.$ZONE. (
    1       ; Número de serie de la zona
    12h     ; Tiempo de refresco de las zonas secundarias
    4h      ; Tiempo de reintento si falla el refresco
    4d      ; Tiempo de expiración de la información secundaria
    2h      ; Tiempo mínimo de caché para respuestas negativas
)

@       IN  NS  dns1.$ZONE.
dns1    IN  A   $ZONE_IP
@       IN  A   $ZONE_IP
EOF

# ---------- 9. COMPROBAR LA CONFIGURACIÓN ----------
echo ">>> Comprobando la configuración..."
sudo named-checkconf && echo "Configuración de BIND9 correcta."
sudo named-checkzone "$ZONE" "/etc/bind/db.$ZONE"

# ---------- 10. REINICIAR Y MOSTRAR EL ESTADO DE BIND9 ----------
sudo systemctl restart bind9
sudo systemctl status bind9 --no-pager | head -n 5

echo "Configuración completada."
