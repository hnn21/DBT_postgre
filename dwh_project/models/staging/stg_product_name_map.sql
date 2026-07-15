select video_id, product_contain, product_contain_combo
from {{ source('raw','product_name_map') }}
