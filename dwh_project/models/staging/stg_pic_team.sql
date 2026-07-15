select raw_name, doi_ten, team
from {{ source('raw','pic_team') }}
