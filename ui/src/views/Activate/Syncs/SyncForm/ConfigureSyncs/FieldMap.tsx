import EntityItem from '@/components/EntityItem';
import { Box, Input, Button, Text, Select } from '@chakra-ui/react';
import TemplateMapping from './TemplateMapping/TemplateMapping';
import { FieldMap as FieldMapType } from '@/views/Activate/Syncs/types';
import { OPTION_TYPE } from './TemplateMapping/TemplateMapping';
import { FiRefreshCcw } from 'react-icons/fi';
import { RJSFSchema } from '@rjsf/utils';
import React, { useEffect, useMemo, useState } from 'react';
import { getCatalog } from '@/services/syncs';


type FieldMapProps = {
  id: number;
  fieldType: 'model' | 'destination' | 'custom';
  icon: string;
  entityName: string;
  handleRefreshCatalog?: () => void;
  options?: string[];
  value?: string;
  disabledOptions?: string[];
  isDisabled: boolean;
  onChange: (
    id: number,
    type: 'model' | 'destination' | 'custom',
    value: string,
    mappingType?: OPTION_TYPE,
    options?: Record<string, unknown>,
  ) => void;
  selectedConfigOptions?: FieldMapType[] | null;
  destinationName?: string;
  destinationSchema?: RJSFSchema;
  destinationId?: string;
};

const RenderRefreshButton = ({ handleRefreshCatalog }: { handleRefreshCatalog: () => void }) => (
  <Button
    color='black.500'
    borderRadius='6px'
    onClick={handleRefreshCatalog}
    leftIcon={<FiRefreshCcw color='gray.100' />}
    backgroundColor='gray.200'
    variant='shell'
    height='32px'
    minWidth={0}
    width='auto'
    fontSize='12px'
    fontWeight={700}
    lineHeight='18px'
    letterSpacing='-0.12px'
  >
    Refresh
  </Button>
);

const FieldMap = ({
  id,
  fieldType,
  icon,
  entityName,
  options,
  value,
  onChange,
  isDisabled,
  selectedConfigOptions,
  handleRefreshCatalog,
  destinationName,
  destinationSchema,
  destinationId,
}: FieldMapProps): JSX.Element => {
  // Helpers to detect if selected destination field is an array (linked record)
  const getSubSchema = (schema: RJSFSchema | undefined, path: string | undefined): RJSFSchema | undefined => {
    if (!schema || !path) return undefined;
    const segments = path
      .split('.')
      .filter((seg) => seg !== '' && seg !== '0' && seg !== '[0]');
    let current: RJSFSchema | undefined = schema;
    for (const seg of segments) {
      if (!current) return undefined;
      if (current.type === 'object' && current.properties && (current.properties as any)[seg]) {
        current = (current.properties as any)[seg] as RJSFSchema;
      } else if (current.type === 'array' && current.items) {
        current = current.items as RJSFSchema;
        if (current?.type === 'object' && current.properties && (current.properties as any)[seg]) {
          current = (current.properties as any)[seg] as RJSFSchema;
        }
      } else {
        return undefined;
      }
    }
    return current;
  };

  const isArrayField = (schema: RJSFSchema | undefined, path?: string): boolean => {
    if (!schema || !path) return false;
    const sub = getSubSchema(schema, path);
    if (!sub) return false;
    const t = sub.type as string | string[] | undefined;
    if (!t) return false;
    return Array.isArray(t) ? t.includes('array') : t === 'array';
  };

  const destinationField = selectedConfigOptions?.[id]?.to as string | undefined;
  const showAirtableLookup =
    fieldType === 'destination' && destinationName === 'Airtable' && isArrayField(destinationSchema, destinationField);
  const currentOptions = (selectedConfigOptions?.[id]?.options as Record<string, unknown>) || {};
  const matchFieldValue = (currentOptions?.match_field as string) || '';
  const linkedTableId = (currentOptions?.linked_table_id as string) || '';

  const [catalogStreams, setCatalogStreams] = useState<Array<{ name: string; url: string; json_schema?: any; x_airtable?: { table_id?: string } }>>([]);
  const [linkedTableFields, setLinkedTableFields] = useState<Array<{ id: string; name: string; type: string }>>([]);

  // Load catalog streams once we know the destination
  useEffect(() => {
    const loadCatalog = async () => {
      try {
        if (destinationName === 'Airtable' && destinationId) {
          const resp = await getCatalog(String(destinationId), false);
          const streams = (resp?.data?.attributes?.catalog?.streams as Array<any>) || [];
          setCatalogStreams(streams.map((s) => ({ name: s?.name, url: s?.url, json_schema: s?.json_schema, x_airtable: s?.x_airtable })));
        } else {
          setCatalogStreams([]);
        }
      } catch (_) {
        setCatalogStreams([]);
      }
    };
    loadCatalog();
  }, [destinationName, destinationId]);

  // Helper: parse tableId from Airtable stream URL (fallback)
  const getTableIdFromUrl = (url?: string): string | null => {
    if (!url) return null;
    try {
      const parts = url.split('/');
      return parts[parts.length - 1] || null;
    } catch {
      return null;
    }
  };

  // Build Linked Table choices from streams
  const linkedTableChoices = useMemo(() => {
    return catalogStreams.map((s) => {
      const tableId = s?.x_airtable?.table_id || getTableIdFromUrl(s.url) || '';
      // Label: use trailing segment of stream name if present
      const label = (s.name || '').split('/').slice(-1)[0] || tableId;
      return { id: tableId, label };
    });
  }, [catalogStreams]);

  // Auto-infer linked table id from destination field schema metadata
  const destinationFieldSchema = destinationField ? getSubSchema(destinationSchema, destinationField) : undefined;
  const directDestinationFieldSchema = (destinationSchema as any)?.properties?.[destinationField as any];
  const inferredLinkedTableId: string =
    ((destinationFieldSchema as any)?.x_airtable?.linked_table_id || directDestinationFieldSchema?.x_airtable?.linked_table_id || '');
  const effectiveLinkedTableId: string = (linkedTableId || inferredLinkedTableId || '');

  // If we can infer linked table id but options don't have it yet, persist it once
  useEffect(() => {
    if (inferredLinkedTableId && !linkedTableId) {
      const fromValue = (selectedConfigOptions?.[id]?.from as string) || '';
      const mergedOptions = { ...currentOptions, linked_table_id: inferredLinkedTableId };
      onChange(id, 'model', fromValue, OPTION_TYPE.CUSTOM_MAPPING, mergedOptions);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [inferredLinkedTableId]);

  // When linked_table_id changes, derive fields from matching stream
  useEffect(() => {
    if (effectiveLinkedTableId && catalogStreams.length > 0) {
      const match = catalogStreams.find((s) => (s?.x_airtable?.table_id || getTableIdFromUrl(s.url)) === effectiveLinkedTableId);
      const props = match?.json_schema?.properties || {};
      const fields = Object.keys(props).map((name) => ({ id: name, name, type: 'unknown' }));
      setLinkedTableFields(fields);
    } else {
      setLinkedTableFields([]);
    }
  }, [effectiveLinkedTableId, catalogStreams]);

  return (
    <Box width='100%'>
      <Box marginBottom='10px' display='flex' justifyContent='space-between'>
        <EntityItem icon={icon} name={entityName} />
        {fieldType === 'destination' && id === 0 && (
          <RenderRefreshButton handleRefreshCatalog={handleRefreshCatalog as () => void} />
        )}
      </Box>
      <Box position='relative'>
        {fieldType === 'custom' ? (
          <Input
            value={value}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) => onChange(id, fieldType, e.target.value)}
            isDisabled={isDisabled}
            borderColor={isDisabled ? 'gray.500' : 'gray.400'}
            backgroundColor={isDisabled ? 'gray.300' : 'gray.100'}
          />
        ) : (
          <>
            <TemplateMapping
              entityName={entityName}
              isDisabled={isDisabled}
              columnOptions={options ? options : []}
              handleUpdateConfig={onChange}
              mappingId={id}
              selectedConfig={
                fieldType === 'model'
                  ? selectedConfigOptions?.[id]?.from
                  : selectedConfigOptions?.[id]?.to
              }
              fieldType={fieldType}
              mappingType={selectedConfigOptions?.[id]?.mapping_type as OPTION_TYPE}
              destinationName={destinationName}
              destinationField={selectedConfigOptions?.[id]?.to}
              destinationSchema={destinationSchema}
            />
            {showAirtableLookup && (
              <Box marginTop='12px' display='flex' flexDirection='column' gap='8px'>
                {!inferredLinkedTableId && (
                  <Box>
                    <Text size='xs' fontWeight='semibold' marginBottom='6px'>Linked table</Text>
                    <Select
                      placeholder='Select a linked table'
                      value={linkedTableId}
                      onChange={(e: React.ChangeEvent<HTMLSelectElement>) => {
                        const fromValue = (selectedConfigOptions?.[id]?.from as string) || '';
                        const mergedOptions = { ...currentOptions, linked_table_id: e.target.value, match_field: '' };
                        onChange(id, 'model', fromValue, OPTION_TYPE.CUSTOM_MAPPING, mergedOptions);
                      }}
                      isDisabled={isDisabled}
                    >
                      {linkedTableChoices.map((t: { id: string; label: string }) => (
                        <option key={t.id} value={t.id}>{t.label}</option>
                      ))}
                    </Select>
                  </Box>
                )}

                <Box>
                  <Text size='xs' fontWeight='semibold' marginBottom='6px'>Lookup by</Text>
                  {linkedTableFields.length > 0 ? (
                    <Select
                      placeholder='Select a field from the linked table'
                      value={matchFieldValue}
                onChange={(e: React.ChangeEvent<HTMLSelectElement>) => {
                        const fromValue = (selectedConfigOptions?.[id]?.from as string) || '';
                        const mergedOptions = { ...currentOptions, match_field: e.target.value };
                        onChange(id, 'model', fromValue, OPTION_TYPE.CUSTOM_MAPPING, mergedOptions);
                  const currentTo = (selectedConfigOptions?.[id]?.to as string) || '';
                  const baseTo = currentTo.split('.')[0] || currentTo;
                  if (baseTo && baseTo !== currentTo) {
                    onChange(id, 'destination', baseTo, OPTION_TYPE.CUSTOM_MAPPING);
                  }
                      }}
                      isDisabled={isDisabled}
                    >
                      {linkedTableFields.map((f: { id: string; name: string }) => (
                        <option key={f.id} value={f.name}>{f.name}</option>
                      ))}
                    </Select>
                  ) : (
                    <Input
                      placeholder='Field in linked table (e.g., Name)'
                      value={matchFieldValue}
                onChange={(e: React.ChangeEvent<HTMLInputElement>) => {
                        const fromValue = (selectedConfigOptions?.[id]?.from as string) || '';
                        const mergedOptions = { ...currentOptions, match_field: e.target.value };
                        onChange(id, 'model', fromValue, OPTION_TYPE.CUSTOM_MAPPING, mergedOptions);
                  const currentTo = (selectedConfigOptions?.[id]?.to as string) || '';
                  const baseTo = currentTo.split('.')[0] || currentTo;
                  if (baseTo && baseTo !== currentTo) {
                    onChange(id, 'destination', baseTo, OPTION_TYPE.CUSTOM_MAPPING);
                  }
                      }}
                      isDisabled={isDisabled}
                      borderColor={isDisabled ? 'gray.500' : 'gray.400'}
                      backgroundColor={isDisabled ? 'gray.300' : 'gray.100'}
                    />
                  )}
                </Box>
              </Box>
            )}
          </>
        )}
      </Box>
    </Box>
  );
};

export default FieldMap;
